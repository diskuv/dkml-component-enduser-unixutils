open Sexplib.Std

type conf = { trust_anchors : string list [@sexp.list] } [@@deriving sexp]

let trust_anchors (cl : Staging_dkmlconfdir_api.Conf_loader.t) =
  let { trust_anchors } = conf_of_sexp cl.sexp in
  trust_anchors
