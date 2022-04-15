open Dkml_install_api
open Dkml_install_register
open Bos

let execute_install ctx =
  Logs.info (fun m ->
      m "The install location is: %a" Fpath.pp
        (ctx.Context.path_eval "%{prefix}%"));
  Logs.info (fun m ->
      m "The detected host ABI is: %s"
        (Context.Abi_v2.to_canonical_string ctx.Context.host_abi_v2));
  if Context.Abi_v2.is_windows ctx.Context.host_abi_v2 then
    Staging_ocamlrun_api.spawn_ocamlrun ctx
      Cmd.(
        v
          (Fpath.to_string
             (ctx.Context.path_eval
                "%{staging-unixutils:share-generic}%/windows_install.bc"))
        %% Log_config.to_args ctx.Context.log_config
        % "--tmp-dir"
        % Fpath.to_string (ctx.Context.path_eval "%{tmp}%")
        % "--target-msys2-dir"
        % Fpath.to_string (ctx.Context.path_eval "%{prefix}%/tools/MSYS2")
        % "--target-sh"
        % Fpath.to_string
            (ctx.Context.path_eval "%{prefix}%/tools/unixutils/bin/sh.exe")
        % "--curl-exe"
        % Fpath.to_string
            (ctx.Context.path_eval "%{staging-curl:share-abi}%/bin/curl.exe")
        %%
        match ctx.Context.host_abi_v2 with
        | Windows_x86 -> v "--32-bit"
        | _ -> empty)
  else
    Staging_ocamlrun_api.spawn_ocamlrun ctx
      Cmd.(
        v
          (Fpath.to_string
             (ctx.Context.path_eval
                "%{staging-unixutils:share-generic}%/unix_install.bc"))
        % "-target-sh"
        % Fpath.to_string
            (ctx.Context.path_eval "%{prefix}%/tools/unixutils/bin/sh"))

let register () =
  let reg = Component_registry.get () in
  Component_registry.add_component reg
    (module struct
      include Default_component_config

      let component_name = "network-unixutils"

      let depends_on =
        [ "staging-ocamlrun"; "staging-curl"; "staging-unixutils" ]

      let install_user_subcommand ~component_name:_ ~subcommand_name ~ctx_t =
        let doc = "Install Unix utilities over the network" in
        Result.ok
        @@ Cmdliner.Term.
             (const execute_install $ ctx_t, info subcommand_name ~doc)
    end)
