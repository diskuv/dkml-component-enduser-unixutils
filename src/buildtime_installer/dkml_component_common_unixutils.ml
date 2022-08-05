open Dkml_install_api

let execute_uninstall ctx =
  Dkml_install_api.uninstall_directory_onerror_exit ~id:"7b357ac9"
    ~dir:(ctx.Context.path_eval "%{prefix}%/tools/unixutils")
    ~wait_seconds_if_stuck:300.;
  Dkml_install_api.uninstall_directory_onerror_exit ~id:"bf9b5e5a"
    ~dir:(ctx.Context.path_eval "%{prefix}%/tools/MSYS2")
    ~wait_seconds_if_stuck:300.;
  (* remove tools/ if and only if it is empty *)
  let toolsdir = ctx.Context.path_eval "%{prefix}%/tools" in
  try Unix.rmdir (Fpath.to_string toolsdir) with
  | Unix.Unix_error (Unix.ENOTEMPTY, _, _) ->
      (* There are still directories or files in tools/. Fine! *)
      Logs.debug (fun l ->
          l "Did not delete %a because it is was not empty" Fpath.pp toolsdir)
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
      (* There was no tools/ directory. Perhaps a previous installation was
         aborted very early. *)
      ()
