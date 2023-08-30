module Arg = Cmdliner.Arg
module Cmd = Cmdliner.Cmd
module Term = Cmdliner.Term

module Installer = struct
  open Bos
  open Staging_dkmlconfdir_api

  let ( let* ) r f =
    match r with
    | Ok v -> f v
    | Error s ->
        Dkml_install_api.Forward_progress.stderr_fatallog ~id:"54c34807"
          (Fmt.str "%a" Rresult.R.pp_msg s);
        exit
          (Dkml_install_api.Forward_progress.Exit_code.to_int_exitcode
             Exit_transient_failure)

  let ( let+ ) f x = Rresult.R.map x f

  type base = Base of string | No_base

  type download_msys2 = {
    curl_exe : Fpath.t;
    msys2_estimated_sz : int;
    msys2_dkml_base_package_file : string;
    msys2_sha256 : string;
  }

  type select_msys2 =
    | Download_msys2 of download_msys2
    | Use_msys2_base_exe of Fpath.t

  type t = {
    (* The "base" installer is friendly for CI (ex. GitLab CI).
       The non-base installer will not work in CI. Will get exit code -1073741515 (0xFFFFFFFFC0000135)
       which is STATUS_DLL_NOT_FOUND; likely a graphical DLL is linked that is not present in headless
       Windows Server based CI systems. *)
    msys2_base : base;
    tmp_dir : string;
    target_sh : string;
    target_msys2_dir : string;
    dkml_confdir_exe : Fpath.t;
    select_msys2 : select_msys2;
  }

  let create ~bits32 ~tmp_dir ~target_sh ~target_msys2_dir ~curl_exe_opt
      ~msys2_base_exe_opt ~dkml_confdir_exe =
    let select_msys2 =
      match (curl_exe_opt, msys2_base_exe_opt, bits32) with
      | _, Some msys2_base_exe, _ -> Use_msys2_base_exe msys2_base_exe
      | Some curl_exe, _, true ->
          (* 32-bit *)
          Download_msys2
            {
              curl_exe;
              msys2_dkml_base_package_file = "65422464";
              msys2_estimated_sz = 64_950 * 1024;
              msys2_sha256 =
                "8a31ef2bcb0f3b9a820e15abe1d75bd1477577f9c218453377296e4f430693a0";
            }
      | Some curl_exe, _, false ->
          (* 64-bit *)
          Download_msys2
            {
              curl_exe;
              msys2_dkml_base_package_file = "65422459";
              msys2_estimated_sz = 76_240 * 1024;
              msys2_sha256 =
                "06977504e0a35b6662d952e59c26e730a191478ff99cb27b2b7886d6605ed787";
            }
      | _ -> failwith "Either --msys2-base-exe or --curl-exe must be specified"
    in
    {
      msys2_base = Base (if bits32 then "msys32" else "msys64");
      tmp_dir;
      target_sh;
      target_msys2_dir;
      dkml_confdir_exe;
      select_msys2;
    }

  let download_file ~curl_exe ~url ~destfile expected_cksum estimated_sz =
    Logs.info (fun m -> m "Downloading %s" url);
    (* Write to a temporary file because, especially on 32-bit systems,
       the RAM to hold the file may overflow. And why waste memory on 64-bit?
       On Windows the temp file needs to be in the same directory as the
       destination file so that the subsequent rename succeeds.
    *)
    let destdir = Fpath.(normalize destfile |> split_base |> fst) in
    let* _already_exists = OS.Dir.create destdir in
    let* tmpfile = OS.File.tmp ~dir:destdir "curlo%s" in
    let protected () =
      let cmd =
        Cmd.(
          v (Fpath.to_string curl_exe)
          % "-L" % "-o" % Fpath.to_string tmpfile % url)
      in
      Dkml_install_api.(log_spawn_onerror_exit ~id:"e6435b12" cmd);
      (match Sys.backend_type with
      | Native | Other _ ->
          Logs.info (fun m -> m "Verifying checksum for %s" url)
      | Bytecode ->
          Logs.info (fun m ->
              m "Verifying checksum for %s using slow bytecode" url));
      let actual_cksum_ctx = ref (Digestif.SHA256.init ()) in
      let one_mb = 1_048_576 in
      let buflen = 32_768 in
      let buffer = Bytes.create buflen in
      let sofar = ref 0 in
      (* This will be piss slow with Digestif bytecode rather than Digestif.c.
         Or perhaps it is file reading; please hook up a profiler!
         TODO: Bundle in native code of digestif.c for both Win32 and Win64,
         or just spawn out to PowerShell `Get-FileHash -Algorithm SHA256`.
         Perhaps even make "sha256sum" be part of unixutils, with wrappers to
         shasum on macOS, sha256sum on Linux and Get-FileHash on Windows ...
         with this slow bytecode as fallback. *)
      let* actual_cksum =
        OS.File.with_input ~bytes:buffer tmpfile
          (fun f () ->
            let rec feedloop = function
              | Some (b, pos, len) ->
                  actual_cksum_ctx :=
                    Digestif.SHA256.feed_bytes !actual_cksum_ctx ~off:pos ~len b;
                  sofar := !sofar + buflen;
                  if !sofar mod one_mb = 0 then
                    Logs.info (fun l ->
                        l "Verified %d of %d MB" (!sofar / one_mb)
                          (estimated_sz / one_mb));
                  feedloop (f ())
              | None -> Digestif.SHA256.get !actual_cksum_ctx
            in
            feedloop (f ()))
          ()
      in
      if Digestif.SHA256.equal expected_cksum actual_cksum then
        Ok (Sys.rename (Fpath.to_string tmpfile) (Fpath.to_string destfile))
      else
        Rresult.R.error_msg
          (Fmt.str
             "Failed to verify the download '%s'. Expected SHA256 checksum \
              '%a' but got '%a'"
             url Digestif.SHA256.pp expected_cksum Digestif.SHA256.pp
             actual_cksum)
    in
    Fun.protect
      ~finally:(fun () ->
        match OS.File.delete tmpfile with
        | Ok () -> ()
        | Error msg ->
            (* Only WARN since this is inside a Fun.protect *)
            Logs.warn (fun l ->
                l "The temporary file %a could not be deleted: %a" Fpath.pp
                  tmpfile Rresult.R.pp_msg msg))
      (fun () -> protected ())

  (** [install_msys2 ~target_dir] installs MSYS2 into [target_dir] *)
  let install_msys2 { msys2_base; target_msys2_dir; tmp_dir; select_msys2; _ } =
    let target_msys2_fp = Fpath.v target_msys2_dir in
    (* Example: DELETE Z:\temp\prefix\tools\MSYS2 *)
    let () =
      Dkml_install_api.uninstall_directory_onerror_exit ~id:"2bfe33f8"
        ~dir:target_msys2_fp ~wait_seconds_if_stuck:300.
    in
    let* destfile =
      match select_msys2 with
      | Download_msys2
          {
            curl_exe;
            msys2_dkml_base_package_file;
            msys2_sha256;
            msys2_estimated_sz;
            _;
          } ->
          let destfile = Fpath.(v tmp_dir / "msys2.exe") in
          let url =
            "https://gitlab.com/dkml/distributions/msys2-dkml-base/-/package_files/"
            ^ msys2_dkml_base_package_file ^ "/download"
          in
          let* () =
            download_file ~curl_exe ~url ~destfile
              (Digestif.SHA256.of_hex msys2_sha256)
              msys2_estimated_sz
          in
          Ok destfile
      | Use_msys2_base_exe msys2_base_exe -> Ok msys2_base_exe
    in
    match msys2_base with
    | Base msys2_basename ->
        (* Example: Z:\temp\prefix\tools, MSYS2 *)
        let target_msys2_parent_fp, _target_msys2_rel_fp =
          Fpath.split_base target_msys2_fp
        in
        (* Example: Z:\temp\prefix\tools\msys64 *)
        let target_msys2_extract_fp =
          Fpath.(target_msys2_parent_fp / msys2_basename)
        in
        let () =
          Dkml_install_api.uninstall_directory_onerror_exit ~id:"d9d7dbee"
            ~dir:target_msys2_extract_fp ~wait_seconds_if_stuck:300.
        in
        Dkml_install_api.log_spawn_onerror_exit ~id:"4010064d"
          Cmd.(
            v (Fpath.to_string destfile)
            % "-y"
            % Fmt.str "-o%a" Fpath.pp target_msys2_parent_fp);
        (* Example: MOVE Z:\temp\prefix\tools\msys64 -> Z:\temp\prefix\tools\MSYS2 *)
        OS.Path.move target_msys2_extract_fp target_msys2_fp
    | No_base ->
        Dkml_install_api.log_spawn_onerror_exit ~id:"8889d18a"
          Cmd.(
            v (Fpath.to_string destfile)
            % "--silentUpdate" % "--verbose"
            % Fpath.to_string target_msys2_fp);
        Ok ()

  (** [install_msys2_dll_in_targetdir ~msys2_dir ~target_dir] copies
      msys-2.0.dll into [target_dir] if it is not already in [target_dir] *)
  let install_msys2_dll_in_targetdir ~msys2_dir ~target_dir =
    let dest = Fpath.(target_dir / "msys-2.0.dll") in
    let* exists = OS.Path.exists dest in
    if exists then Ok ()
    else
      Rresult.R.error_to_msg ~pp_error:Fmt.string
        (Diskuvbox.copy_file
           ~src:Fpath.(msys2_dir / "usr" / "bin" / "msys-2.0.dll")
           ~dst:dest ())

  (** [install_trust_anchors ~msys2_dir ~trust_anchors] *)
  let install_trust_anchors ~msys2_dir ~trust_anchors =
    (* https://www.msys2.org/docs/faq/#how-can-i-make-msys2pacman-trust-my-companys-custom-tls-ca-certificate *)
    let* () =
      Result.map_error Rresult.R.msg
        (List.fold_left
           (fun res trust_anchor ->
             match res with
             | Ok () ->
                 Logs.info (fun l ->
                     l "Using [trust_anchor %a]" Fpath.pp trust_anchor);
                 Diskuvbox.copy_file ~src:trust_anchor
                   ~dst:
                     Fpath.(
                       msys2_dir / "etc" / "pki" / "ca-trust" / "source"
                       / "anchors"
                       / Fpath.basename trust_anchor)
                   ()
             | Error e -> Error e)
           (Ok ()) trust_anchors)
    in
    match trust_anchors with
    | [] -> Ok ()
    | _ ->
        let env = Fpath.(msys2_dir / "usr" / "bin" / "env.exe") in
        let bindir = Fpath.(msys2_dir / "usr" / "bin") in
        let update_ca_trust =
          Fpath.(msys2_dir / "usr" / "bin" / "update-ca-trust")
        in
        Dkml_install_api.log_spawn_onerror_exit ~id:"dd58fe8b"
          Cmd.(
            v (Fpath.to_string env)
            % "MSYSTEM=MSYS" % "MSYSTEM_PREFIX=/usr"
            % Fmt.str "PATH=%a" Fpath.pp bindir
            % "dash"
            % (match Logs.level () with
              | Some Logs.Debug | Some Logs.Info -> "-eufx"
              | _ -> "-euf")
            % Fpath.to_string update_ca_trust);
        Ok ()

  (** [install_sh ~target] makes a copy of /bin/dash.exe
      to [target], and adds msys-2.0.dll if not present. *)
  let install_sh ~msys2_dir ~target =
    let search = [ Fpath.(msys2_dir / "usr" / "bin") ] in
    let* src_sh_opt = OS.Cmd.find_tool ~search (Cmd.v "dash") in
    match src_sh_opt with
    | None ->
        Rresult.R.error_msg
        @@ Fmt.str "Could not find dash.exe in %a"
             Fmt.(Dump.list Fpath.pp)
             search
    | Some src_sh ->
        let target_dir = Fpath.parent target in
        let* (_created : bool) = OS.Dir.create ~mode:0o750 target_dir in
        Rresult.R.error_to_msg ~pp_error:Fmt.string
          (let* () = install_msys2_dll_in_targetdir ~msys2_dir ~target_dir in
           Diskuvbox.copy_file ~src:src_sh ~dst:target ())

  let install_utilities t =
    let target_msys2_dir = Fpath.v t.target_msys2_dir in
    let sequence =
      let* () = install_msys2 t in
      let model_conf =
        Conf_loader.create_from_system_confdir ~unit_name:"unixutils"
          ~dkml_confdir_exe:t.dkml_confdir_exe
      in
      let trust_anchors =
        List.map Fpath.v (Model_conf.trust_anchors model_conf)
      in
      let* () =
        install_trust_anchors ~msys2_dir:target_msys2_dir ~trust_anchors
      in
      install_sh ~msys2_dir:target_msys2_dir ~target:(Fpath.v t.target_sh)
    in
    match sequence with
    | Ok () -> ()
    | Error e ->
        Dkml_install_api.Forward_progress.stderr_fatallog ~id:"59391a58"
          (Fmt.str "%a" Rresult.R.pp_msg e);
        exit
          (Dkml_install_api.Forward_progress.Exit_code.to_int_exitcode
             Exit_transient_failure)
end

(** [install] runs the installation *)
let install (_log_config : Dkml_install_api.Log_config.t) bits32 tmp_dir
    target_msys2_dir target_sh curl_exe_opt msys2_base_exe_opt dkml_confdir_exe
    =
  let installer =
    Installer.create ~bits32 ~tmp_dir ~target_msys2_dir ~target_sh ~curl_exe_opt
      ~msys2_base_exe_opt ~dkml_confdir_exe
  in
  Installer.install_utilities installer

(** {1 Command line parsing} *)

let setup_log style_renderer level =
  Fmt_tty.setup_std_outputs ?style_renderer ();
  Logs.set_level level;
  Logs.set_reporter (Logs_fmt.reporter ());
  Dkml_install_api.Log_config.create ?log_config_style_renderer:style_renderer
    ?log_config_level:level ()

let setup_log_t =
  Term.(const setup_log $ Fmt_cli.style_renderer () $ Logs_cli.level ())

let bits32_t =
  let doc =
    "Install 32-bit MSYS2. Use with caution since MSYS2 deprecated 32-bit in \
     May 2020."
  in
  Arg.(value & flag & info ~doc [ "32-bit" ])

let tmp_dir_t =
  let doc = "Temporary directory" in
  Arg.(required & opt (some dir) None & info ~doc [ "tmp-dir" ])

let target_msys2_dir_t =
  let doc = "Destination directory for MSYS2" in
  Arg.(required & opt (some string) None & info ~doc [ "target-msys2-dir" ])

let target_sh_t =
  let doc = "Destination path for a symlink to MSYS2's /bin/dash.exe" in
  Arg.(required & opt (some string) None & info ~doc [ "target-sh" ])

let curl_exe_opt_t =
  let doc =
    "Location of curl.exe. Required only if --msys2-base-exe is not specified"
  in
  let v = Arg.(value & opt (some file) None & info ~doc [ "curl-exe" ]) in
  Term.(const (Option.map Fpath.v) $ v)

let msys2_base_exe_opt_t =
  let doc =
    "Location of msys2-base-ARCH-DATE.sfx.exe. If not specified, --curl-exe \
     will be used to download MSYS2"
  in
  let v = Arg.(value & opt (some file) None & info ~doc [ "msys2-base-exe" ]) in
  Term.(const (Option.map Fpath.v) $ v)

let dkml_confdir_exe_t =
  let doc = "The location of dkml-confdir.exe" in
  let v =
    Arg.(required & opt (some file) None & info ~doc [ "dkml-confdir-exe" ])
  in
  Term.(const Fpath.v $ v)

let main_t =
  Term.(
    const install $ setup_log_t $ bits32_t $ tmp_dir_t $ target_msys2_dir_t
    $ target_sh_t $ curl_exe_opt_t $ msys2_base_exe_opt_t $ dkml_confdir_exe_t)

let () = exit (Cmd.eval (Cmd.v (Cmd.info "windows-install") main_t))
