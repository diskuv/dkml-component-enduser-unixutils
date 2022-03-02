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
    target_sh : string;
    target_msys2_dir : string;
    curl_exe : string;
  }

  let create ~bit32 ~target_sh ~target_msys2_dir ~curl_exe =
    if bit32 then
      {
        (* There is no 32-bit base installer, so have to use the automated but graphical installer. *)
        msys2_setup_exe_basename = "msys2-i686-20200517.exe";
        msys2_url_path = "2020-05-17/msys2-i686-20200517.exe";
        msys2_sha256 =
          "e478c521d4849c0e96cf6b4a0e59fe512b6a96aa2eb00388e77f8f4bc8886794";
        msys2_base = No_base;
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
        target_sh;
        target_msys2_dir;
        curl_exe;
      }

  let copy_file src dst =
    let* mode = OS.Path.Mode.get src in
    let* data = OS.File.read src in
    OS.File.write ~mode dst data

  (** [install_msys2 ~target_dir] installs MSYS2 into [target_dir] *)
  let install_msys2
      {
        (* msys2_setup_exe_basename; *)
        msys2_url_path;
        (* msys2_sha256; *)
        (* msys2_base; *)
        (* target_msys2_dir; *)
        curl_exe;
        _;
      } =
    let url =
      "https://github.com/msys2/msys2-installer/releases/download/"
      ^ msys2_url_path
    in
    match Curly.(run ~exe:curl_exe (Request.make ~url ~meth:`GET ())) with
    | Ok x ->
        Logs.info (fun m -> m "status: %d\n" x.Curly.Response.code);
        Logs.info (fun m ->
            m "headers: %a\n" Curly.Header.pp x.Curly.Response.headers);
        Logs.info (fun m ->
            m "Location: %a\n"
              Fmt.(option string)
              (List.assoc_opt "location" x.Curly.Response.headers));
        (* Format.printf "body: %s\n" x.Curly.Response.body; *)
        Result.ok ()
    | Error e -> Rresult.R.error_msg (Fmt.str "%a" Curly.Error.pp e)

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
    let search = [ Fpath.(msys2_dir / "bin") ] in
    let* src_sh = OS.Cmd.get_tool ~search (Cmd.v "dash") in
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
    Rresult.R.error_msg_to_invalid_arg sequence
end

let () =
  let anon_fun (_ : string) = () in
  let bit32 = ref false in
  let target_msys2_dir = ref "" in
  let target_sh = ref "" in
  let curl_exe = ref "" in
  Arg.(
    parse
      [
        ( "-32bit",
          Unit (fun () -> bit32 := true),
          "Install 32-bit MSYS2. Use with caution since MSYS2 deprecated \
           32-bit in May 2020." );
        ( "-target-msys2-dir",
          Set_string target_msys2_dir,
          "Destination directory for MSYS2" );
        ( "-target-sh",
          Set_string target_sh,
          "Destination path for a symlink to MSYS2's /bin/dash.exe" );
        ("-curl-exe", Set_string curl_exe, "Location of curl or curl.exe");
      ]
      anon_fun "Install on Windows");
  (* Setup logs. Perhaps we should use cmdliner so log settings can be propagated? *)
  Fmt_tty.setup_std_outputs ();
  Logs.set_level (Some Logs.Info);
  Logs.set_reporter (Logs_fmt.reporter ());
  (* Run installation *)
  let installer =
    Installer.create ~bit32:!bit32 ~target_msys2_dir:!target_msys2_dir
      ~target_sh:!target_sh ~curl_exe:!curl_exe
  in
  Installer.install_utilities installer
