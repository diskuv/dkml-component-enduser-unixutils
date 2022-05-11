open Cmdliner

module Installer = struct
  open Bos

  let ( let* ) r f =
    match r with
    | Ok v -> f v
    | Error s ->
        raise
          (Dkml_install_api.Installation_error (Fmt.str "%a" Rresult.R.pp_msg s))

  let ( let+ ) f x = Rresult.R.map x f

  type base = Base of string | No_base

  type t = {
    msys2_setup_exe_basename : string;
    msys2_sz : int;
    msys2_url_path : string;
    msys2_sha256 : string;
    (* The "base" installer is friendly for CI (ex. GitLab CI).
       The non-base installer will not work in CI. Will get exit code -1073741515 (0xFFFFFFFFC0000135)
       which is STATUS_DLL_NOT_FOUND; likely a graphical DLL is linked that is not present in headless
       Windows Server based CI systems. *)
    msys2_base : base;
    tmp_dir : string;
    target_sh : string;
    target_msys2_dir : string;
    curl_exe : string;
  }

  (** Always use MSYS2 64-bit regardless of [bits32] because MSYS2 32-bit
      installer is deprecated. Can use MSYS2 CLANG32 repository for
      32-bit compiled packages however. *)
  let create ~bits32:_ ~tmp_dir ~target_sh ~target_msys2_dir ~curl_exe =
    {
      msys2_setup_exe_basename = "msys2-base-x86_64-20220128.sfx.exe";
      msys2_url_path = "2022-01-28/msys2-base-x86_64-20220128.sfx.exe";
      msys2_sz = 70183704;
      msys2_sha256 =
        "ac6aa4e96af36a5ae207e683963b270eb8cecd7e26d29b48241b5d43421805d4";
      msys2_base = Base "msys64";
      tmp_dir;
      target_sh;
      target_msys2_dir;
      curl_exe;
    }

  (* TODO: Place in diskuvbox *)
  let chmod_plus_readwrite_dir dir =
    let ( >>= ) = Result.bind in
    let raise_fold_error fpath result =
      Rresult.R.error_msgf
        "@[A chmod u+rw directory operation errored out while visiting %a.@]@,\
         @[  @[%a@]@]" Fpath.pp fpath
        (Rresult.R.pp
           ~ok:(Fmt.any "<unknown rmdir problem>")
           ~error:Rresult.R.pp_msg)
        result
    in
    let chmod_u_rw rel = function
      | Error _ as e ->
          (* no more chmod if we had an error *)
          e
      | Ok () ->
          let path = Fpath.(dir // rel) in
          let* mode = OS.Path.Mode.get path in
          if mode land 0o600 <> 0o600 then
            let+ () = OS.Path.Mode.set path (mode lor 0o600) in
            ()
          else Result.ok ()
    in
    OS.Path.fold ~err:raise_fold_error chmod_u_rw (Result.ok ()) [ dir ]
    >>= function
    | Ok () -> Result.ok ()
    | Error s ->
        Rresult.R.error_msg
          (Fmt.str
             "@[@[Failed to chmod u+rw the directory@]@[@ %a@]@ .@]@ @[%a@]"
             Fpath.pp dir Rresult.R.pp_msg s)

  (* TODO: Place in diskuvbox *)
  let remove_dir ?verbose dir =
    (* On Windows we need to get write access before you can delete the
       file. *)
    let* exists = OS.Path.exists dir in
    if exists then (
      if verbose = Some true then
        Logs.info (fun m -> m "Removing directory %a" Fpath.pp dir);
      let* () = chmod_plus_readwrite_dir dir in
      OS.Dir.delete ~recurse:true dir)
    else Result.ok ()

  let download_file { curl_exe; _ } url destfile expected_cksum expected_sz =
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
        Cmd.(v curl_exe % "-L" % "-o" % Fpath.to_string tmpfile % url)
      in
      Dkml_install_api.log_spawn_and_raise cmd;
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
                          (expected_sz / one_mb));
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
  let install_msys2
      ({
         msys2_url_path;
         msys2_sha256;
         msys2_sz;
         msys2_base;
         target_msys2_dir;
         tmp_dir;
         _;
       } as t) =
    let url =
      "https://github.com/msys2/msys2-installer/releases/download/"
      ^ msys2_url_path
    in
    let target_msys2_fp = Fpath.v target_msys2_dir in
    (* Example: DELETE Z:\temp\prefix\tools\MSYS2 *)
    let* () = remove_dir ~verbose:true target_msys2_fp in
    let destfile = Fpath.(v tmp_dir / "msys2.exe") in
    let* () =
      download_file t url destfile
        (Digestif.SHA256.of_hex msys2_sha256)
        msys2_sz
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
        let* () = remove_dir target_msys2_extract_fp in
        Dkml_install_api.log_spawn_and_raise
          Cmd.(
            v (Fpath.to_string destfile)
            % "-y"
            % Fmt.str "-o%a" Fpath.pp target_msys2_parent_fp);
        (* Example: MOVE Z:\temp\prefix\tools\msys64 -> Z:\temp\prefix\tools\MSYS2 *)
        OS.Path.move target_msys2_extract_fp target_msys2_fp
    | No_base ->
        Dkml_install_api.log_spawn_and_raise
          Cmd.(
            v (Fpath.to_string destfile)
            % "--silentUpdate" % "--verbose"
            % Fpath.to_string target_msys2_fp);
        Result.ok ()

  (** [install_msys2_dll_in_targetdir ~msys2_dir ~target_dir] copies
      msys-2.0.dll into [target_dir] if it is not already in [target_dir] *)
  let install_msys2_dll_in_targetdir ~msys2_dir ~target_dir =
    let dest = Fpath.(target_dir / "msys-2.0.dll") in
    let* exists = OS.Path.exists dest in
    if exists then Result.ok ()
    else
      Rresult.R.error_to_msg ~pp_error:Fmt.string
        (Diskuvbox.copy_file
           ~src:Fpath.(msys2_dir / "usr" / "bin" / "msys-2.0.dll")
           ~dst:dest ())

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
      install_sh ~msys2_dir:target_msys2_dir ~target:(Fpath.v t.target_sh)
    in
    match sequence with
    | Ok () -> ()
    | Error e ->
        raise
          (Dkml_install_api.Installation_error (Fmt.str "%a" Rresult.R.pp_msg e))
end

(** [install] runs the installation *)
let install (_log_config : Dkml_install_api.Log_config.t) bits32 tmp_dir
    target_msys2_dir target_sh curl_exe =
  let installer =
    Installer.create ~bits32 ~tmp_dir ~target_msys2_dir ~target_sh ~curl_exe
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

let curl_exe_t =
  let doc = "Location of curl.exe" in
  Arg.(required & opt (some file) None & info ~doc [ "curl-exe" ])

let main_t =
  Term.(
    const install $ setup_log_t $ bits32_t $ tmp_dir_t $ target_msys2_dir_t
    $ target_sh_t $ curl_exe_t)

let () = Term.(exit @@ eval (main_t, info "windows-install"))
