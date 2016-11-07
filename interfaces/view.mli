
(* Prints a description of who's turn it is. *)
val print_turn : model -> ()

(* Prompts the user for whether he rolls dice or not. *)
val prompt_move : Agent.move list -> string

(* Prints a description of whether the player elected to Roll or Passage. *)
val print_move : Agent.move -> ()

(* Prompts the user for his. *)
val prompt_movement : (string * loc) list -> string

val print_movement : (string * loc) -> ()