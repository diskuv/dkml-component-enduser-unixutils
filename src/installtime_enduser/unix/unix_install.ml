module Installer = struct
  open Bos

  let ( let* ) = Rresult.R.( >>= )

  type t = { target_sh : string }

  let create ~target_sh = { target_sh }

  (** [install_sh ~target] makes a symlink from /bin/dash
      or /bin/sh to [target]. *)
  let install_sh ~link_sh =
    let search = [ Fpath.v "/bin" ] in
    let* src_sh_opt = OS.Cmd.find_tool ~search (Cmd.v "dash") in
    let* target =
      match src_sh_opt with
      | Some src -> Ok src
      | None -> OS.Cmd.get_tool ~search (Cmd.v "sh")
    in
    let* _was_created = OS.Dir.create ~mode:0o750 (Fpath.parent link_sh) in
    OS.Path.symlink ~target link_sh

  let install_utilities { target_sh } =
    let sequence = install_sh ~link_sh:(Fpath.v target_sh) in
    Rresult.R.error_msg_to_invalid_arg sequence
end

let () =
  let anon_fun (_ : string) = () in
  let target_sh = ref "" in
  Arg.(
    parse
      [
        ( "-target-sh",
          Set_string target_sh,
          "Destination path for a symlink to the POSIX shell (/bin/dash, \
           /bin/sh) on the PATH" );
      ]
      anon_fun "Install on Unix");
  if !target_sh = "" then (
    prerr_endline "FATAL: The -target-sh PATH option is required.";
    exit 1);
  let installer = Installer.create ~target_sh:!target_sh in
  Installer.install_utilities installer
