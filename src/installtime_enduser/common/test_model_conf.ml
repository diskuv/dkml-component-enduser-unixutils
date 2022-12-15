open Unixutils_install_common.Model_conf

let sexp s = Sexplib.Sexp.of_string s

let test_empty () =
  Alcotest.(check (list string))
    "same strings" []
    (trust_anchors (create_from_sexp (sexp "()")))

let test_one_trust_anchor () =
  Alcotest.(check (list string))
    "same strings" [ "C:\\conf\\my.pem" ]
    (trust_anchors
       (create_from_sexp (sexp {|((trust_anchors ("C:\\conf\\my.pem")))|})))

let test_two_trust_anchors () =
  Alcotest.(check (list string))
    "same strings"
    [ "C:\\conf\\my.pem"; "D:\\conf\\my.cer" ]
    (trust_anchors
       (create_from_sexp
          (sexp {|((trust_anchors ("C:\\conf\\my.pem" "D:\\conf\\my.cer")))|})))

let () =
  let open Alcotest in
  run "model_conf"
    [
      ( "basic",
        [
          test_case "empty" `Quick test_empty;
          test_case "one" `Quick test_one_trust_anchor;
          test_case "two" `Quick test_two_trust_anchors;
        ] );
    ]
