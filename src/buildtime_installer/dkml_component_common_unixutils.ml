open Dkml_install_api

let execute_uninstall ctx =
  Dkml_install_api.uninstall_directory_onerror_exit ~id:"7b357ac9"
    ~dir:(ctx.Context.path_eval "%{prefix}%/tools/unixutils")
    ~wait_seconds_if_stuck:300.;
  Dkml_install_api.uninstall_directory_onerror_exit ~id:"bf9b5e5a"
    ~dir:(ctx.Context.path_eval "%{prefix}%/tools/MSYS2")
    ~wait_seconds_if_stuck:300.;
  (* remove tools/ if and only if it is empty *)
  try Unix.rmdir (Fpath.to_string @@ ctx.Context.path_eval "%{prefix}%/tools")
  with Unix.Unix_error (Unix.ENOTEMPTY, _, _) -> ()
