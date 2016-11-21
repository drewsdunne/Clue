open View
open Cli
open Model
open Data
open Agent

module Display = Cli

(* Thrown when there are no players in a player list. *)
exception No_players

(* Thrown when a player is not found in a player list *)
exception Player_not_found

(* Gets the current player and the next player in the players list.
 * If the provided player string is not found it will raise an error. *)
let get_cur_next plrs cur =
  let rec helper ps t =
    match t with
    | [] -> raise Player_not_found
    | c::n::t' ->
      if c.suspect = cur then (c, n) else helper ps (n::t')
    | h::[] when h.suspect = cur -> (h, List.hd ps)
    | h::[] -> helper ps []
  in if plrs = [] then raise No_players else helper plrs plrs

(* Gets a string describing the movement. *)
let string_of_movement l = match l with
  | Room_Rect(s, _) ->
    "Entered "^s
  | Space(x,y) ->
    "Landed on space "^(string_of_int x)^", "^(string_of_int y)

(* Handles the agent's option of passage or dice roll. If dice has been rolled,
 * then the agent is asked where they would like to move. That location is
 * then displayed. *)
let handle_move game curr_p m =
  match m with
  | Roll ->
    let dice_roll = (Random.int 11) + 2 in
    let () = Display.display_dice_roll dice_roll in
    let movement_opt = Model.get_movement_options game dice_roll in
    let movement = Agent.get_movement curr_p game.public movement_opt in
    let () = Display.display_movement (string_of_movement movement.info, movement)
    in movement
  | Passage l -> l

(* Handles certain locations and returns the type of action that takes place
 * after landing in this location. *)
let handle_movement game = function
  | Room_Rect(s, _) when s = game.public.acc_room -> `Accusation
  | Room_Rect(_, _) -> `Guess
  | _ -> `End_turn

(* Takes in a player and if a player with the same suspect is in the list,
 * pl replaces that player. Tail recursive. *)
let replace_player pl lst =
  let rec helper pls t =
    match t with
    | [] -> pls
    | pl'::t' when pl'.suspect = pl.suspect -> helper (pl::pls) t'
    | pl'::t' -> helper (pl'::pls) t'
  in List.rev (helper [] lst)

(* Checks if any [Human_t] players in the list are not out. If a player is
 * out then [is_out] will be true. *)
let rec check_for_humans pls =
  match pls with
  | [] -> false
  | pl::t -> if not pl.is_out && pl.agent = Human_t then true
             else check_for_humans t

(* Checks if all players are out. [] = all players are out. Tail recursive. *)
let rec check_all_out pls =
  match pls with
  | [] -> true
  | pl::t -> if pl.is_out then check_for_humans t else false

(* Reorders the plrs list so pl is at the end. Specifically it splits the
 * list at pl, puts the tail at the front and the players from hd to pl
 * (inclusive) at the back. Not tail recursive.
 * Requires: pl is in plrs *)
let reorder_pls pl plrs =
  let rec helper ps t =
    match t with
    | [] -> []@(List.rev ps)
    | h::t' when h.suspect = pl.suspect -> (t')@(List.rev (pl::ps))
    | h::t' -> helper (h::ps) t'
  in helper [] plrs

let make_envelope_if data =
  match data.card_info with
  | Unknown -> {data with card_info=Envelope}
  | _ -> data


let show_person card pl sheet =
  let data = CardMap.find card sheet in
  let card_info = match data.card_info with
    | Mine l -> Mine (pl.suspect::l)
    | x -> x in
  let data' = {data with card_info=card_info} in
  CardMap.add card data' sheet


(* [step] Recursively progresses through the game by doing one agent turn
 * at a time.
 * Requires: game has at least one player. *)
let rec step game =
  let (curr_p, next_p) = get_cur_next game.players game.public.curr_player in
  if curr_p.is_out then
    if not (check_all_out game.players) then
      step {game with public={game.public with curr_player=next_p.suspect}}
    else Display.display_message "Game over."
  else
    let () = Display.display_turn game.public in
    let move_ops = Model.get_move_options game in
    let move = Agent.answer_move curr_p game.public move_ops in
    let () = Display.display_move move in
    let movement = handle_move game curr_p move in
    let curr_p' = {curr_p with curr_loc = movement} in
    match handle_movement game movement.info with
    | `Accusation -> handle_accusation curr_p' next_p game
    | `Guess -> handle_guess curr_p next_p game
    | `End_turn -> handle_end_turn curr_p' next_p game

(* [handle_accusation curr_p next_p game] gets the current player and asks for
 * their final game accusation. If they are wrong, they are set to out, and
 * the model is updated and then step is called. If they are correct, the game
 * ends and they are pronounced the winner. *)
and handle_accusation curr_p next_p game =
  let guess = Agent.get_accusation curr_p game.public in
  let () = Display.display_guess guess in
  if guess = game.envelope then
    Display.display_victory curr_p.suspect
  else (* Lose, out *)
    let message =
      (curr_p.suspect^" guessed incorrectly, and is out of the game.") in
    let () = Display.display_message message in
    let curr_p' = {curr_p with is_out = true} in
    let pls' = replace_player curr_p' game.players in
    let guard = (game.ai_only || check_for_humans pls') in
    if guard && not (check_all_out pls') then
      let pub = {game.public with curr_player=next_p.suspect} in
      step {game with players = pls'; public = pub}
    else
      Display.display_message "Game over."

(* [handle_guess curr_p next_p game] takes in the current player, the next
 * player and the game state and performs actions for getting a guess from
 * the current player and then any possible shown cards will be gathered and
 * shown if possible. *)
and handle_guess curr_p next_p game =
  let (s, w, r) as guess = Agent.get_guess curr_p game.public in
  let () = Display.display_guess guess in
  let group = reorder_pls curr_p game.players in
  let rec get_answers pls =
    match pls with
    | [] -> None
    | pl::t when pl.suspect = curr_p.suspect -> None
    | pl::t -> extract_answer pl t
  and extract_answer pl t =
    match Agent.get_answer pl game.public guess with
    | None -> get_answers t
    | Some card -> Some (pl, card)
  in match get_answers group with
  | None -> (* No card could be shown *)
    let s_data = CardMap.find s curr_p.sheet in
    let s_data' = make_envelope_if s_data in
    let w_data = CardMap.find w curr_p.sheet in
    let w_data' = make_envelope_if w_data in
    let r_data = CardMap.find r curr_p.sheet in
    let r_data' = make_envelope_if r_data in
    let sheet' = CardMap.add s s_data' curr_p.sheet
      |> CardMap.add w w_data'
      |> CardMap.add r r_data' in
    let curr_p' = {curr_p with sheet = sheet'} in
    let pls' = replace_player curr_p' game.players in
    let pub = {game.public with curr_player=next_p.suspect} in
    step {game with players = pls'; public = pub}
  | Some (pl, card) -> (* A card was shown by pl *)
    let data = CardMap.find card curr_p.sheet in
    let data' = {data with card_info= ShownBy(pl.suspect)} in
    let sheet' = CardMap.add card data' curr_p.sheet in
    let curr_p' = {curr_p with sheet= sheet'} in
    let pl' = {pl with sheet= (show_person card curr_p pl.sheet)} in
    let pls' = replace_player curr_p' game.players |> replace_player pl' in
    let pub = {game.public with curr_player=next_p.suspect} in
    step {game with players = pls'; public = pub}

(* [handle_end_turn curr_p next_p game] is called when the current player
 * lands on a space and the turn essentially ends. The game model is updated
 * and then step is called again. *)
and handle_end_turn curr_p next_p game =
  let pub = {game.public with curr_player=next_p.suspect} in
  let pls = replace_player curr_p game.players in
  step {game with public=pub; players=pls}

(* Called when starting a game. Loads the provided file if given. Takes a
 * string option. *)
let start file_name =
  let load_go fl =
    try step (Model.import_board fl) with
    | No_players -> Display.display_error "No players in game file"
    | Player_not_found -> Display.display_error "No player with suspect name"
  in match file_name with
  | None -> load_go (Display.prompt_filename ())
  | Some s -> load_go s