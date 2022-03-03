open Cmdliner

module Installer = struct
  open Bos

  let ( let* ) = Rresult.R.bind

  let ( let+ ) f x = Rresult.R.map x f

  type base = Base of string | No_base

  type t = {
    msys2_setup_exe_basename : string;
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

  let create ~bits32 ~tmp_dir ~target_sh ~target_msys2_dir ~curl_exe =
    if bits32 then
      {
        (* There is no 32-bit base installer, so have to use the automated but graphical installer. *)
        msys2_setup_exe_basename = "msys2-i686-20200517.exe";
        msys2_url_path = "2020-05-17/msys2-i686-20200517.exe";
        msys2_sha256 =
          "e478c521d4849c0e96cf6b4a0e59fe512b6a96aa2eb00388e77f8f4bc8886794";
        msys2_base = No_base;
        tmp_dir;
        target_sh;
        target_msys2_dir;
        curl_exe;
      }
    else
      {
        msys2_setup_exe_basename = "msys2-base-x86_64-20220128.sfx.exe";
        msys2_url_path = "2022-01-28/msys2-base-x86_64-20220128.sfx.exe";
        msys2_sha256 =
          "ac6aa4e96af36a5ae207e683963b270eb8cecd7e26d29b48241b5d43421805d4";
        msys2_base = Base "msys64";
        tmp_dir;
        target_sh;
        target_msys2_dir;
        curl_exe;
      }

  let copy_file src dst =
    let* mode = OS.Path.Mode.get src in
    let* data = OS.File.read src in
    OS.File.write ~mode dst data

  let download_file { curl_exe; _ } url destfile expected_cksum =
    Logs.info (fun m -> m "Downloading %s" url);
    let rec helper ~redirects_remaining ~visited current_url =
      match Curly.get ~exe:curl_exe current_url with
      | Ok x when x.Curly.Response.code = 302 -> (
          match
            ( redirects_remaining <= 0,
              List.assoc_opt "location" x.Curly.Response.headers )
          with
          | true, _ ->
              Rresult.R.error_msg
                (Fmt.str
                   "@[Redirects did not stop during download.@]@ @[Visited: \
                    @[%a@]@]"
                   Fmt.(list ~sep:(sps 0) string)
                   (List.rev (current_url :: visited)))
          | false, None ->
              Rresult.R.error_msg
                (Fmt.str
                   "During download of '%s', HTTP 302 received from '%s' with \
                    no Location header"
                   url current_url)
          | false, Some redirect_location ->
              Logs.debug (fun m -> m "Redirecting to: %s" redirect_location);
              helper ~redirects_remaining:(redirects_remaining - 1)
                ~visited:(current_url :: visited) redirect_location)
      | Ok x ->
          let actual_cksum = Sha256.string x.Curly.Response.body in
          (* Sha256.equal is buggy in at least 1.15.1! *)
          let expected_cksum_hex = Sha256.to_hex expected_cksum in
          let actual_cksum_hex = Sha256.to_hex actual_cksum in
          if expected_cksum_hex = actual_cksum_hex then
            let* (_created : bool) = OS.Dir.create (Fpath.parent destfile) in
            OS.File.write destfile x.Curly.Response.body
          else
            Rresult.R.error_msg
              (Fmt.str
                 "Failed to verify the download '%s'. Expected SHA256 checksum \
                  '%s' but got '%s'"
                 url expected_cksum_hex actual_cksum_hex)
      | Error e ->
          Rresult.R.error_msg
            (Fmt.str "Error during download of '%s': %a" url Curly.Error.pp e)
    in
    helper ~redirects_remaining:3 ~visited:[] url

  (** [install_msys2 ~target_dir] installs MSYS2 into [target_dir] *)
  let install_msys2
      ({
         (* msys2_setup_exe_basename; *)
         msys2_url_path;
         msys2_sha256;
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
    let* () = OS.Dir.delete ~recurse:true target_msys2_fp in
    let destfile = Fpath.(v tmp_dir / "msys2.exe") in
    let* () = download_file t url destfile (Sha256.of_hex msys2_sha256) in
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
        let* () = OS.Dir.delete ~recurse:true target_msys2_extract_fp in
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
            % "in" % "--confirm-command" % "--accept-messages" % "--root"
            % Fpath.to_string target_msys2_fp);
        Result.ok ()

  (** [install_msys2_dll_in_targetdir ~msys2_dir ~target_dir] copies
      msys-2.0.dll into [target_dir] if it is not already in [target_dir] *)
  let install_msys2_dll_in_targetdir ~msys2_dir ~target_dir =
    let dest = Fpath.(target_dir / "msys-2.0.dll") in
    let* exists = OS.Path.exists dest in
    if exists then Result.ok ()
    else copy_file Fpath.(msys2_dir / "bin" / "msys-2.0.dll") dest

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
        Unix.mkdir (Fpath.to_string target_dir) 0o750;
        let* () = install_msys2_dll_in_targetdir ~msys2_dir ~target_dir in
        copy_file src_sh target

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
