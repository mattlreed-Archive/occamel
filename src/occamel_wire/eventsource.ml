(* Port of eventsource-parser v3.1.0 (MIT), pinned at
   83db3dec52a3494e22ee7e6eb4e1349380f75e36 — see docs/ports/eventsource-parser.md.
   Behavior mirrors upstream byte-for-byte (validated by differential fuzzing);
   deliberate divergences are listed in the provenance doc. *)

type event = { id : string option; event_type : string option; data : string }

type error =
  | Invalid_retry of { value : string; line : string }
  | Unknown_field of { field : string; value : string; line : string }
  | Buffer_limit_exceeded of { limit : int }

type output =
  | Event of event
  | Retry of int
  | Comment of string
  | Parse_error of error

type t = {
  max_buffer_size : int option;
  first_chunk : bool;
  (* Bytes since the last line terminator, as reversed fragments. Joined
     only when a terminator arrives, so a huge line fed in tiny slices stays
     linear instead of O(n^2) re-concatenation (mirrors upstream). *)
  pending_rev : string list;
  pending_len : int;
  (* Per-event buffers (WHATWG "last event ID", "data", "event type"). Data
     is kept as reversed lines and joined with '\n' at dispatch; [data_len]
     tracks the joined length (incl. separators) for the resource bound. *)
  id : string option;
  data_rev : string list;
  data_len : int;
  event_type : string option;
  terminated : bool;
}

let create ?max_buffer_size () =
  {
    max_buffer_size;
    first_chunk = true;
    pending_rev = [];
    pending_len = 0;
    id = None;
    data_rev = [];
    data_len = 0;
    event_type = None;
    terminated = false;
  }

let is_terminated t = t.terminated

(* Mutable scratch state for a single [feed]/[reset ~consume] call. The
   public API stays persistent; this keeps the inner loop allocation-light. *)
type session = {
  mutable s_id : string option;
  mutable s_data_rev : string list;
  mutable s_data_len : int;
  mutable s_event_type : string option;
  mutable s_out_rev : output list;
}

let session_of t =
  {
    s_id = t.id;
    s_data_rev = t.data_rev;
    s_data_len = t.data_len;
    s_event_type = t.event_type;
    s_out_rev = [];
  }

let emit s o = s.s_out_rev <- o :: s.s_out_rev

let append_data s v =
  s.s_data_len <-
    (match s.s_data_rev with
    | [] -> String.length v
    | _ -> s.s_data_len + 1 + String.length v);
  s.s_data_rev <- v :: s.s_data_rev

let clear_event_buffers s =
  s.s_id <- None;
  s.s_data_rev <- [];
  s.s_data_len <- 0;
  s.s_event_type <- None

(* Blank line: dispatch the buffered event, if it has any data lines.
   Note: upstream (deliberately, contra WHATWG) also clears the [id] buffer
   between events rather than persisting the last event ID — we mirror it. *)
let dispatch s =
  (match s.s_data_rev with
  | [] -> ()
  | lines ->
      emit s
        (Event
           {
             id = s.s_id;
             event_type = s.s_event_type;
             data = String.concat "\n" (List.rev lines);
           }));
  clear_event_buffers s

(* [prefix] matched against [chunk] within [start_, end_) only. Upstream
   reads past the line end unguarded; that is equivalent because line
   terminators can never match a prefix character (proved safe by fuzzing,
   but we bound it anyway). *)
let has_prefix chunk start_ end_ prefix =
  let plen = String.length prefix in
  end_ - start_ >= plen
  &&
  let rec go i = i = plen || (chunk.[start_ + i] = prefix.[i] && go (i + 1)) in
  go 0

(* Field value: bytes from [vstart] to [end_), minus at most one leading
   space (SSE strips a single space after the colon). *)
let value_from chunk vstart end_ =
  let vstart = if vstart < end_ && chunk.[vstart] = ' ' then vstart + 1 else vstart in
  String.sub chunk vstart (end_ - vstart)

let is_ascii_digits v =
  v <> "" && String.for_all (fun c -> c >= '0' && c <= '9') v

(* Base-10 parse of an all-digit string, saturating at [max_int] (upstream's
   parseInt degrades to imprecise floats there; we saturate — divergence
   documented, differential harness normalizes values > 1e15). *)
let saturating_int_of_digits v =
  let n = String.length v in
  let rec go i acc =
    if i = n then acc
    else
      let d = Char.code v.[i] - Char.code '0' in
      if acc > (max_int - d) / 10 then max_int else go (i + 1) ((acc * 10) + d)
  in
  go 0 0

let set_event_type s v = s.s_event_type <- (if v = "" then None else Some v)

(* Per spec, an id containing NUL is ignored; upstream additionally resets
   the buffer to undefined (rather than keeping the previous value) — mirrored. *)
let set_id s v = s.s_id <- (if String.contains v '\000' then None else Some v)

(* Slow-path field dispatch for lines that are not data:/event:/id:/comment.
   Field names compare literally — no case folding, per spec. *)
let process_field s ~field ~value ~line =
  match field with
  | "event" -> set_event_type s value
  | "data" -> append_data s value
  | "id" -> set_id s value
  | "retry" ->
      if is_ascii_digits value then emit s (Retry (saturating_int_of_digits value))
      else emit s (Parse_error (Invalid_retry { value; line }))
  | _ -> emit s (Parse_error (Unknown_field { field; value; line }))

(* One complete line: [start_, end_) excludes the terminator. *)
let parse_line s chunk start_ end_ =
  if start_ = end_ then dispatch s
  else if has_prefix chunk start_ end_ "data:" then
    append_data s (value_from chunk (start_ + 5) end_)
  else if has_prefix chunk start_ end_ "event:" then
    set_event_type s (value_from chunk (start_ + 6) end_)
  else if has_prefix chunk start_ end_ "id:" then
    set_id s (value_from chunk (start_ + 3) end_)
  else if chunk.[start_] = ':' then
    emit s (Comment (value_from chunk (start_ + 1) end_))
  else begin
    let line = String.sub chunk start_ (end_ - start_) in
    match String.index_opt line ':' with
    | None ->
        (* No colon: the whole line is the field name, value is empty. *)
        process_field s ~field:line ~value:"" ~line
    | Some i ->
        let field = String.sub line 0 i in
        let value = value_from line (i + 1) (String.length line) in
        process_field s ~field ~value ~line
  end

(* Split [chunk] into lines terminated by LF, CR, or CRLF and parse each;
   return trailing bytes that lack a terminator. A CR as the very last byte
   is ambiguous (its LF may arrive in the next chunk) and is deferred. *)
let process_lines s chunk =
  let n = String.length chunk in
  if not (String.contains chunk '\r') then begin
    (* Fast path: LF-only chunk (the overwhelmingly common case). *)
    let search = ref 0 in
    let continue_ = ref true in
    while !continue_ do
      match String.index_from_opt chunk !search '\n' with
      | None -> continue_ := false
      | Some e ->
          parse_line s chunk !search e;
          search := e + 1
    done;
    String.sub chunk !search (n - !search)
  end
  else begin
    (* General path. Next-CR/next-LF positions are cached and re-scanned
       only once passed, keeping the whole chunk linear. *)
    let search = ref 0 in
    let cr = ref (String.index_from_opt chunk 0 '\r') in
    let lf = ref (String.index_from_opt chunk 0 '\n') in
    let stop = ref false in
    while not !stop do
      (match !cr with
      | Some c when c < !search -> cr := String.index_from_opt chunk !search '\r'
      | _ -> ());
      (match !lf with
      | Some l when l < !search -> lf := String.index_from_opt chunk !search '\n'
      | _ -> ());
      let line_end =
        match (!cr, !lf) with
        | Some c, Some l -> Some (min c l)
        | Some c, None -> if c = n - 1 then None (* deferred trailing CR *) else Some c
        | None, Some l -> Some l
        | None, None -> None
      in
      match line_end with
      | None -> stop := true
      | Some e ->
          parse_line s chunk !search e;
          search := e + 1;
          (* CRLF counts as a single terminator, not CR + blank line. *)
          if chunk.[e] = '\r' && !search < n && chunk.[!search] = '\n' then incr search
    done;
    String.sub chunk !search (n - !search)
  end

(* One leading UTF-8 BOM is stripped, and only off the very first chunk of
   the stream (mirrors upstream: a BOM split across the first two chunks is
   NOT stripped — recorded as an upstream quirk). *)
let strip_bom chunk =
  if
    String.length chunk >= 3
    && chunk.[0] = '\xef'
    && chunk.[1] = '\xbb'
    && chunk.[2] = '\xbf'
  then String.sub chunk 3 (String.length chunk - 3)
  else chunk

let has_terminator chunk = String.contains chunk '\n' || String.contains chunk '\r'

let feed t chunk =
  if t.terminated then (t, [])
  else begin
    let chunk = if t.first_chunk then strip_bom chunk else chunk in
    let s = session_of t in
    let pending_rev, pending_len =
      match t.pending_rev with
      | [] ->
          let trailing = process_lines s chunk in
          if trailing = "" then ([], 0) else ([ trailing ], String.length trailing)
      | pending when not (has_terminator chunk) ->
          (* Still no terminator: buffer the fragment without joining. *)
          (chunk :: pending, t.pending_len + String.length chunk)
      | pending ->
          let input = String.concat "" (List.rev (chunk :: pending)) in
          let trailing = process_lines s input in
          if trailing = "" then ([], 0) else ([ trailing ], String.length trailing)
    in
    (* §13.8 resource bound, checked once per feed as upstream does. *)
    match t.max_buffer_size with
    | Some limit when pending_len + s.s_data_len > limit ->
        emit s (Parse_error (Buffer_limit_exceeded { limit }));
        ( {
            t with
            first_chunk = false;
            pending_rev = [];
            pending_len = 0;
            id = None;
            data_rev = [];
            data_len = 0;
            event_type = None;
            terminated = true;
          },
          List.rev s.s_out_rev )
    | _ ->
        ( {
            t with
            first_chunk = false;
            pending_rev;
            pending_len;
            id = s.s_id;
            data_rev = s.s_data_rev;
            data_len = s.s_data_len;
            event_type = s.s_event_type;
          },
          List.rev s.s_out_rev )
  end

let reset ?(consume = false) t =
  let out =
    match t.pending_rev with
    | fragments when consume && fragments <> [] ->
        (* Parse the buffered incomplete line as if newline-terminated. Any
           buffer mutations are discarded (the parser resets below); only
           emitted outputs survive — mirrors upstream. *)
        let s = session_of t in
        let line = String.concat "" (List.rev fragments) in
        parse_line s line 0 (String.length line);
        List.rev s.s_out_rev
    | _ -> []
  in
  (create ?max_buffer_size:t.max_buffer_size (), out)
