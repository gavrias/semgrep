(*
   Match a parsed pattern against a parsed document.

   Expectations:

   1. A flat (non-indented) pattern may match both a flat and an indented
      document.
   2. An indented pattern may only match an indented document.

   i.e. if the user bothers indenting their pattern, we honor this constraint.

   Example
   -------

   pattern:

     f(x) { a; }

   matching document:

     f(x) { a; }

   other matching document:

     f(x) {
       a;
     }

   other matching document:

     f(x)
     {
       a; }

*)

open Printf
open Doc_AST
open Pattern_AST

let debug = ref false

(*** Public types ***)

type pattern_id = int

type region = Loc.t * Loc.t

type capture = {
  name: string;
  value: string;
  loc: Loc.t;
}

type match_ = {
  region: region;
  captures: capture list;
}

(*** Internal types ***)

(* Map from metavariables to their captured value, which is a Word. *)
module Env = Map.Make (String)
type env = (Loc.t * string) Env.t

type match_result =
  | Complete of env * Loc.t
  | Fail

(* Continuation that matches the pattern against the empty document.
   To be used as the last argument of the 'match_' function. *)
let rec full_match ~dots env last_loc pat =
  match pat with
  | [] -> Complete (env, last_loc)
  | Dots _ :: pat -> full_match ~dots env last_loc pat
  | [End] -> Complete (env, last_loc)
  | End :: _ -> assert false
  | _ -> Fail

let loc_lnum (loc : Loc.t) =
  let pos, _ = loc in
  pos.pos_lnum

(*
   Find the rightmost location in a document and return it only if it's
   not too far (past the maximum line max_line_num).
 *)
let rec extend_last_loc ~max_line_num last_loc (doc : Doc_AST.node list) =
  match doc with
  | [] -> Some last_loc
  | List doc1 :: doc2 ->
      (match extend_last_loc ~max_line_num last_loc doc1 with
       | None -> None
       | Some last_loc ->
           extend_last_loc ~max_line_num last_loc doc2
      )
  | Atom (loc, _) :: doc ->
      if loc_lnum loc <= max_line_num then
        extend_last_loc ~max_line_num loc doc
      else
        None

let doc_matches_dots ~dots last_loc doc =
  match dots, doc with
  | None, [] -> Some last_loc
  | None, _ -> None
  | Some max_line_num, doc ->
      if loc_lnum last_loc <= max_line_num then
        extend_last_loc ~max_line_num last_loc doc
      else
        None

let rec pat_matches_empty_doc pat =
  match pat with
  | []
  | End :: _ -> true
  | Atom _ :: _ -> false
  | Dots _ :: pat -> pat_matches_empty_doc pat
  | List pat1 :: pat2 ->
      pat_matches_empty_doc pat1
      && pat_matches_empty_doc pat2

(*
   A document atom is skippable if we're within an ellipsis (dots)
   pattern and within 10 lines from the last atom matched before the ellipsis.
*)
let is_skippable_doc_atom ~dots loc =
  match dots with
  | None -> false
  | Some max_line_num ->
      loc_lnum loc <= max_line_num

(*
   A document atom can always be considered for a match unless we're
   matching an ellipsis and the location of the atom is more than 10 lines
   down the last atom matched before the ellipsis.
*)
let within_ellipsis_range ~dots loc =
  match dots with
  | None -> true (* <-- difference with 'is_skippable' *)
  | Some max_line_num ->
      loc_lnum loc <= max_line_num

(*
   Create or update the 'dots' object which indicates:
   1. that we're allowing to skip document nodes that don't match;
   2. and until which line we allow this skipping.
*)
let extend_dots ~dots (last_loc : Loc.t) =
  let ellipsis_max_span = 10 (* lines *) in
  match dots with
  | None ->
      (* allow '...' to extend for at most 10 lines *)
      let _, last_pos = last_loc in
      Some (last_pos.pos_lnum + ellipsis_max_span)
  | Some line_num ->
      Some (line_num + ellipsis_max_span)

(*
   Match a pattern against a document tree.

   dots:
     Some max_line_num
     indicates we're allowed to skip the first document node if it doesn't
     match the pattern. The line number of the skipped node may not
     be greater than the specified value.
   cont:
     call to match the rest of the document against the rest of the
     pattern when reaching the end of the current sub-document.
   last_loc:
     location of the last document node that is part of the current match,
     not including nodes skipped due an ellipsis (dots). This is used
     to determine how far an ellipsis can span, and extend it if another
     '...' is found.
*)
let rec match_
    ~(dots:int option)
    (env : env)
    (last_loc : Loc.t)
    (pat : Pattern_AST.node list )
    (doc : Doc_AST.node list)
    (cont : (dots:int option ->
             env -> Loc.t -> Pattern_AST.node list -> match_result))
  : match_result =
  if !debug then
    Print_match.print pat doc;
  match pat, doc with
  | [], doc ->
      (match doc_matches_dots ~dots last_loc doc with
       | Some last_loc ->
           Complete (env, last_loc)
       | None ->
           Fail
      )
  | [End], doc ->
      (match doc_matches_dots ~dots last_loc doc with
       | Some last_loc ->
           Complete (env, last_loc)
       | None ->
           Complete (env, last_loc)
      )
  | End :: _, _ -> assert false

  | List pat1 :: pat2, doc ->
      (match doc with
       | [] ->
           (* No document left to match against. *)
           assert (pat1 <> []);
           if pat_matches_empty_doc pat1 && pat_matches_empty_doc pat2 then
             Complete (env, last_loc)
           else
             Fail
       | List doc1 :: doc2 ->
           (* Indented block coincides with an indented block in the document.
              These blocks must match, independently from the rest. *)
           (match match_ ~dots:None env last_loc pat1 doc1 full_match with
            | Complete (env, last_loc) ->
                match_ ~dots:None env last_loc pat2 doc2 cont
            | Fail -> Fail
           )
       | Atom (loc, _) :: doc_tail ->
           (* Indented block in pattern doesn't match in the document.
              Skip document node if allowed. *)
           assert (pat1 <> []);
           if is_skippable_doc_atom ~dots loc then
             match_ ~dots env last_loc pat doc_tail cont
           else if pat_matches_empty_doc pat1 then
             match_ ~dots env last_loc pat2 doc cont
           else
             Fail
      )

  | Dots _ :: pat_tail, doc ->
      let dots = extend_dots ~dots last_loc in
      match_ ~dots env last_loc pat_tail doc cont

  | Atom (_, p) :: pat_tail, doc ->
      match doc with
      | [] -> cont ~dots env last_loc pat
      | doc_head :: doc_tail ->
          match doc_head with
          | List sub_doc ->
              (* Indented block in the document doesn't have to match
                 indented block in the pattern. We just continue matching
                 in the block as if the document was flat. *)
              match_ ~dots env last_loc pat sub_doc
                (fun ~dots env last_loc pat ->
                   (* The sub-block was matched but some of the pattern wasn't
                      consumed. We continue, in the sub-block's parent. *)
                   match_ ~dots env last_loc pat doc_tail cont
              )
          | Atom (loc, d) ->
              if not (within_ellipsis_range ~dots loc) then
                Fail
              else
                let match_result =
                  match p, d with
                  | Metavar name, Word value ->
                      (match Env.find_opt name env with
                       | None ->
                           (* First encounter of the metavariable,
                              store its value. *)
                           let env = Env.add name (loc, value) env in
                           match_ ~dots:None env loc pat_tail doc_tail cont
                       | Some (_loc0, value0) ->
                           (* Check if value matches previously captured
                              value. *)
                           if value = value0 then
                             match_ ~dots:None env loc pat_tail doc_tail cont
                           else
                             Fail
                      )
                  | Word a, Word b when a = b ->
                      match_ ~dots:None env loc pat_tail doc_tail cont
                  | Punct a, Punct b when a = b ->
                      match_ ~dots:None env loc pat_tail doc_tail cont
                  | Byte a, Byte b when a = b ->
                      match_ ~dots:None env loc pat_tail doc_tail cont
                  | _ ->
                      Fail
                in
                match match_result with
                | Complete _ -> match_result
                | Fail ->
                    (* Pattern doesn't match document.
                       Skip document's head node if we're allowed to. *)
                    if is_skippable_doc_atom ~dots loc then
                      match_ ~dots env last_loc pat doc_tail cont
                    else
                      Fail

let starts_after last_loc loc =
  let _, last_pos = last_loc in
  let pos, _ = loc in
  Loc.Pos.compare last_pos pos < 0

let rec get_start_loc (doc : Doc_AST.node list) =
  match doc with
  | [] -> None
  | Atom (loc, _) :: _ -> Some loc
  | List doc1 :: doc2 ->
      match get_start_loc doc1 with
      | None -> get_start_loc doc2
      | res -> res

let rec fold acc (doc : Doc_AST.node list) f =
  match doc with
  | [] -> acc
  | Atom (loc, _) :: doc_tail ->
      let acc = f acc loc doc in
      fold acc doc_tail f
  | List doc1 :: doc2 ->
      let acc = fold acc doc1 f in
      fold acc doc2 f

let convert_captures env =
  Env.bindings env
  |> List.map (fun (name, (loc, value)) ->
    {
      name;
      value;
      loc;
    }
  )

(*
   Search for non-overlapping matches.
   last_loc is a forbidden start location. Any attempt to match must start
   from a location after last_loc.
*)
let search pat doc =
  fold [] doc (fun matches start_loc doc ->
    let ok_loc =
      match matches with
      | [] -> true
      | { region = (_, last_loc) } :: _ -> starts_after last_loc start_loc
    in
    if ok_loc then
      match
        match_ ~dots:None Env.empty start_loc pat doc full_match
      with
      | Complete (env, last_loc) ->
          let match_ =
            let region = (start_loc, last_loc) in
            let captures = convert_captures env in
            { region; captures }
          in
          match_ :: matches
      | Fail -> matches
    else
      matches
  )
  |> List.rev

let ansi_highlight s =
  match s with
  | "" -> s
  | s -> ANSITerminal.(sprintf [Bold; green] "%s" s)

let make_separator_printer () =
  let is_first = ref true in
  fun () ->
    if !is_first then
      is_first := false
    else
      print_char '\n'

let print
    ?(highlight = false)
    ?(print_optional_separator = make_separator_printer ())
    src matches =
  let highlight_fun =
    if highlight then Some ansi_highlight
    else None
  in
  let line_prefix =
    match Src_file.source src with
    | File path -> sprintf "%s:" path
    | Stdin | String | Channel -> ""
  in
  List.iter (fun match_ ->
    print_optional_separator ();
    let (start_loc, end_loc) = match_.region in
    if !debug then
      printf "match from %s to %s\n"
        (Loc.show start_loc) (Loc.show end_loc);
    Src_file.lines_of_loc_range
      ?highlight:highlight_fun
      ~line_prefix
      src start_loc end_loc
    |> print_string
  ) matches

let print_nested_results
    ?highlight
    ?(print_optional_separator = make_separator_printer ())
    doc_matches =
  List.iter (fun (src, pat_matches) ->
    List.iter (fun (pat_id, matches) ->
      print ?highlight ~print_optional_separator src matches
    ) pat_matches
  ) doc_matches
