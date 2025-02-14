open Asllib
open Test_helpers.Helpers
module BV = Bitvector

let _debug = false

let of_string_to_string () =
  let one s =
    let res = s |> BV.of_string |> BV.to_string in
    assert (String.equal s res)
  in
  List.iter one
    [
      "'1100'";
      "'10110101'";
      "''";
      "'1010101010101010'";
      "'11001100101'";
      "'1110000000001101'";
      "'11110000111100001111'";
    ]

let test_not () =
  let one (s1, s2) =
    let res = s1 |> BV.of_string |> BV.lognot |> BV.to_string in
    assert (String.equal res s2)
  in
  List.iter one
    [
      ("''", "''");
      ("'0'", "'1'");
      ("'1'", "'0'");
      ("'1010'", "'0101'");
      ("'11110000'", "'00001111'");
      ("'111100001111'", "'000011110000'");
      ("'11110000111100001111'", "'00001111000011110000'");
    ]

let test_equal () =
  let one (b, s1, s2) =
    let bv1 = BV.of_string s1 and bv2 = BV.of_string s2 in
    let res = BV.equal bv1 bv2 in
    let () =
      if _debug then
        Format.(
          eprintf "@[<v>%a %s %a@]@." BV.pp_t bv1
            (if res then "==" else "!=")
            BV.pp_t bv2)
    in
    assert (b = res)
  in
  List.iter one
    [
      (true, "''", "''");
      (true, "'1'", "'1'");
      (false, "'1'", "'0'");
      (false, "'10'", "'11'");
      (true, "'10'", "'10'");
      (true, "'1010'", "'1010'");
      (false, "'1010'", "'1011'");
      (true, "'11110000'", "'11110000'");
      (false, "'11110000'", "'10110000'");
      (true, "'111100001111'", "'111100001111'");
      (false, "'111100001111'", "'111100001110'");
      (false, "'111100001111'", "'111101001111'");
      (false, "'111100001111'", "'101100001111'");
      (true, "'11110000111100001111'", "'11110000111100001111'");
      (false, "'11110000111100001111'", "'11110000111000001111'");
      (false, "'11110000111100001111'", "'11110000111101001111'");
      (false, "'11110000111100001111'", "'11110000111100001101'");
      (false, "'11110000111100001111'", "'11010000111100001111'");
      (false, "'11110000111100001111'", "'11110010111100001111'");
    ]

let test_and () =
  let one (s1, s2, s3) =
    let bv1 = BV.of_string s1
    and bv2 = BV.of_string s2
    and bv3 = BV.of_string s3 in
    let res = BV.logand bv1 bv2 in
    let () =
      if _debug then
        Format.(
          eprintf "@[<v>%a /\\ %a = %a (expected: %a)@]@." BV.pp_t bv1 BV.pp_t
            bv2 BV.pp_t res BV.pp_t bv3)
    in
    assert (BV.equal res bv3)
  in
  List.iter one
    [
      ("'1'", "'1'", "'1'");
      ("'1'", "'0'", "'0'");
      ("'0'", "'1'", "'0'");
      ("'0'", "'0'", "'0'");
      ("'10'", "'11'", "'10'");
      ("'10'", "'01'", "'00'");
      ("'11110000'", "'11001100'", "'11000000'");
      ("'111100001111'", "'110011001100'", "'110000001100'");
      ("'1111000011001100'", "'1100110011110000'", "'1100000011000000'");
    ]

let test_with_ints () =
  let one (i, s) =
    let () =
      if _debug then
        Format.eprintf "Comparing %d and %a => %d@." i BV.pp_t (BV.of_string s)
          (BV.to_int (BV.of_string s))
    in
    (* assert (BV.equal (BV.of_int i) (BV.of_string s)); *)
    (* assert (String.equal (BV.to_string (BV.of_int i)) s); *)
    assert (Int.equal i (BV.to_int (BV.of_string s)));
    assert (Int.equal i (BV.to_int (BV.of_int i)))
  in
  List.iter one
    [
      (0x0, "''");
      (0x0, "'0'");
      (0x0, "'000'");
      (0x1, "'1'");
      (0x1, "'01'");
      (0x1, "'0000000001'");
      (0x100, "'100000000'");
      (0x100, "'00100000000'");
      (0x502, "'10100000010'");
      (0x30502, "'110000010100000010'");
      (0x20502, "'100000010100000010'");
    ]

let test_with_int64 () =
  let one (i, s) =
    let s = Printf.sprintf "'%64s'" s in
    let s = String.map (function ' ' -> '0' | c -> c) s in
    let () =
      if _debug then
        Format.eprintf "Comparing %s to %s (%a to %a)@." (Int64.to_string i) s
          BV.pp_t (BV.of_int64 i) BV.pp_t (BV.of_string s)
    in
    assert (BV.equal (BV.of_int64 i) (BV.of_string s));
    assert (String.equal (BV.to_string (BV.of_int64 i)) s);
    assert (Int64.equal i (BV.to_int64 (BV.of_string s)));
    assert (Int64.equal i (BV.to_int64 (BV.of_int64 i)))
  in
  List.iter one
    [
      (0x0L, "");
      (0x0L, "0");
      (0x0L, "000");
      (0x1L, "1");
      (0x1L, "01");
      (0x1L, "0000000001");
      (0x100L, "100000000");
      (0x100L, "00100000000");
      (0x502L, "10100000010");
      (0x30502L, "110000010100000010");
      (0x20502L, "100000010100000010");
    ]

let test_read_slice () =
  let one (src, positions, expected) =
    let src = BV.of_string src and expected = BV.of_string expected in
    let result = BV.extract_slice src positions in
    let () =
      if _debug then
        Format.eprintf "@[Reading %a at positions @[<h>[%a]@]@ --> %a (%B)@]@."
          BV.pp_t src
          Format.(pp_print_list ~pp_sep:pp_print_space pp_print_int)
          positions BV.pp_t result (BV.equal expected result)
    in
    assert (BV.equal expected result)
  in
  List.iter one
    [
      ("1111000011001100", [], "");
      ("1111000011001100", [ 2 ], "1");
      ("1111000011001100", [ 1 ], "0");
      ("1111000011001100", [ 10 ], "0");
      ("1111000011001100", [ 12 ], "1");
      ("1111000011001100", [ 0; 1; 2; 3 ], "0011");
      ("1111000011001100", [ 3; 2; 1; 0 ], "1100");
      ("1111000011001100", [ 4; 3; 2; 1 ], "0110");
      ("1111000011001100", [ 9; 8; 7; 6 ], "0011");
      ("1111000011001100", [ 15; 0; 15; 0 ], "1010");
    ]

let test_write_slice () =
  let one (dst, positions, src, expected) =
    let src = BV.of_string src
    and dst = BV.of_string dst
    and expected = BV.of_string expected in
    let result = BV.write_slice dst src positions in
    let () =
      if _debug then
        Format.(
          eprintf
            "@[<hv 4>Writing %a to positions @[<h>[%a]@]@ into %a@ gave %a@;\
             <1 4>(%a was expected).@]@." BV.pp_t src
            (pp_print_list ~pp_sep:pp_print_space pp_print_int)
            positions BV.pp_t dst BV.pp_t result BV.pp_t expected)
    in
    assert (BV.equal expected result)
  in
  List.iter one
    [
      ("1111000011001100", [], "", "1111000011001100");
      ("1111000011001100", [ 0 ], "0", "1111000011001100");
      ("1111000011001100", [ 0 ], "1", "1111000011001101");
      ("1111000011001100", [ 3 ], "0", "1111000011000100");
      ("1111000011001100", [ 12 ], "0", "1110000011001100");
      ("1111000011001100", [ 3; 2; 1; 0 ], "0011", "1111000011000011");
      ("1111000011001100", [ 0; 1; 2; 3 ], "1100", "1111000011000011");
      ("1111000011001100", [ 15; 9; 8; 7 ], "0110", "0111001101001100");
    ]

let test_concat () =
  let one args =
    let expected = String.concat "" args in
    let result = BV.concat @@ List.map BV.of_string args in
    let expected = BV.of_string expected in
    let () =
      if _debug then
        Format.eprintf "Assert %a = %a@." BV.pp_t result BV.pp_t expected
    in
    assert (BV.equal result expected)
  in
  List.iter one
    [
      [];
      [ "1100" ];
      [ "1100"; "11110000" ];
      [ "11110000"; "101" ];
      [ "0011110000"; "11" ];
      [ "11"; "010"; "10"; "110011001"; "10" ];
      [ "11"; "0011001"; "1111" ];
      [ "11"; "110011001"; "11" ];
      [ "11"; "00110011001"; "11" ];
      [ "11"; "101011001"; "11" ];
      [ "11"; "011001"; "11" ];
      [ "11110000"; "0101"; "1010"; "0011" ];
      [ "11110000"; "0101"; "1010"; "011" ];
    ]

let () =
  exec_tests
    [
      ("bitvector/of_string_to_string", of_string_to_string);
      ("bitvector/not", test_not);
      ("bitvector/equal", test_equal);
      ("bitvector/and", test_and);
      ("bitvector/with_ints", test_with_ints);
      ("bitvector/with_int64", test_with_int64);
      ("bitvector/read_slice", test_read_slice);
      ("bitvector/write_slice", test_write_slice);
      ("bitvector/concat", test_concat);
    ]
