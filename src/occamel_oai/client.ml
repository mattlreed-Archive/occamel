(* Minimal OpenAI-compatible client for M0: non-streaming chat completions
   with response_format json_schema, over plain HTTP (local Ollama).
   Every failure is a variant — nothing raises across this boundary.

   Endpoint quirk (record for the design doc §B.1 quirk table): the /v1
   surface exposes temperature/top_p/max_tokens but NOT Ollama-native
   options like top_k or num_ctx — those need /api/chat or a Modelfile. *)

type message = { role : string; content : string }

type json_schema_format = { name : string; strict : bool; schema : Yojson.Safe.t }

type config = {
  base_url : string;  (* e.g. "http://localhost:11434/v1" *)
  model : string;
  temperature : float option;
  top_p : float option;
  max_tokens : int option;
}

type usage = { prompt_tokens : int; completion_tokens : int }

type reply = { content : string; usage : usage option }

type error =
  | Transport of string           (* connection refused, timeout, ... *)
  | Http of { status : int; body : string }
  | Bad_response of string        (* 200 but the body isn't what we expect *)

let error_to_string = function
  | Transport msg -> "transport: " ^ msg
  | Http { status; body } ->
      Printf.sprintf "http %d: %s" status
        (if String.length body > 300 then String.sub body 0 300 ^ "…" else body)
  | Bad_response msg -> "bad response: " ^ msg

let request_body ~config ~messages ~response_format : string =
  let opt name f = function Some v -> [ (name, f v) ] | None -> [] in
  let fmt =
    match response_format with
    | None -> []
    | Some { name; strict; schema } ->
        [
          ( "response_format",
            `Assoc
              [
                ("type", `String "json_schema");
                ( "json_schema",
                  `Assoc
                    [
                      ("name", `String name);
                      ("strict", `Bool strict);
                      ("schema", schema);
                    ] );
              ] );
        ]
  in
  `Assoc
    ([
       ("model", `String config.model);
       ( "messages",
         `List
           (List.map
              (fun { role; content } ->
                `Assoc [ ("role", `String role); ("content", `String content) ])
              messages) );
       ("stream", `Bool false);
     ]
    @ opt "temperature" (fun v -> `Float v) config.temperature
    @ opt "top_p" (fun v -> `Float v) config.top_p
    @ opt "max_tokens" (fun v -> `Int v) config.max_tokens
    @ fmt)
  |> Yojson.Safe.to_string

let parse_reply (body : string) : (reply, error) result =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error msg -> Error (Bad_response ("invalid JSON: " ^ msg))
  | json -> (
      let open Yojson.Safe.Util in
      match json |> member "choices" |> index 0 |> member "message" |> member "content" with
      | `String content ->
          let usage =
            match
              ( json |> member "usage" |> member "prompt_tokens",
                json |> member "usage" |> member "completion_tokens" )
            with
            | `Int prompt_tokens, `Int completion_tokens ->
                Some { prompt_tokens; completion_tokens }
            | _ -> None
          in
          Ok { content; usage }
      | _ -> Error (Bad_response "no choices[0].message.content string")
      | exception Type_error (msg, _) -> Error (Bad_response msg))

let chat ~sw ~net (config : config) ?response_format ~(messages : message list) () :
    (reply, error) result =
  let uri = Uri.of_string (config.base_url ^ "/chat/completions") in
  let body = request_body ~config ~messages ~response_format in
  let headers = Http.Header.of_list [ ("content-type", "application/json") ] in
  match
    let client = Cohttp_eio.Client.make ~https:None net in
    let resp, body_reader =
      Cohttp_eio.Client.post client ~sw ~headers
        ~body:(Cohttp_eio.Body.of_string body)
        uri
    in
    let status = Http.Response.status resp |> Http.Status.to_int in
    let body_str =
      Eio.Buf_read.(parse_exn take_all) body_reader ~max_size:(16 * 1024 * 1024)
    in
    (status, body_str)
  with
  | exception exn -> Error (Transport (Printexc.to_string exn))
  | 200, body_str -> parse_reply body_str
  | status, body_str -> Error (Http { status; body = body_str })
