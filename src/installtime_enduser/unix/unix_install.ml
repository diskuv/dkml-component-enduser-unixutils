module Installer = struct
  open Bos

  let ( let* ) = Rresult.R.( >>= )

  type t = { target_sh : string }

  let create ~target_sh = { target_sh }

  (** [install_sh ~target] makes a symlink from /bin/dash
      or /bin/sh to [target]. *)
  let install_sh ~target =
    let search = [ Fpath.v "/bin" ] in
    let* src_sh_opt = OS.Cmd.find_tool ~search (Cmd.v "dash") in
    let* src_sh =
      match src_sh_opt with
      | Some src -> Result.ok src
      | None -> OS.Cmd.get_tool ~search (Cmd.v "sh")
    in
    Unix.mkdir (Fpath.to_string (Fpath.parent target)) 0o750;
    OS.Path.symlink ~target src_sh

  let install_utilities { target_sh } =
    let sequence = install_sh ~target:(Fpath.v target_sh) in
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
  let installer = Installer.create ~target_sh:!target_sh in
  Installer.install_utilities installer
