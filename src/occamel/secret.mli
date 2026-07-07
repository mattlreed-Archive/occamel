(* Secrets hygiene (design doc §13.9). A [Secret.t] wraps an API key or other
   credential such that:
   - it has NO yojson codec and NO to_string — serializing one is a *compile
     error*, so it cannot leak into a trace, repair prompt, or log by accident;
   - its Format printer and [inspect] show only a redacted placeholder;
   - the real bytes are reachable ONLY through [use], which hands them to a
     callback (so the plaintext never becomes a first-class value that could be
     stored or logged).

   Sourced from the environment / a keychain, never from model output. *)

type t

val of_env : string -> t option
(* read a secret from an environment variable; None if unset/empty *)

val of_string : string -> t
(* wrap a known-secret string (e.g. from a keychain helper) *)

val use : t -> (string -> 'a) -> 'a
(* the only way to read the plaintext: pass it to a callback. Do not let it
   escape (don't [use s Fun.id]). *)

val redacted : t -> string
(* a stable, non-reversible placeholder: "<secret:md5-prefix>" *)

val pp : Format.formatter -> t -> unit
(* prints [redacted] — safe in %a and log lines *)
