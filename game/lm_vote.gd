extends Node

## The players choose the next house: dot-map's job, done the way the brief asked, through
## dot-vote.
##
## [DotVoteDirector] over a [DotVoteListSource] of this server's houses. There are no rounds
## here — the server never ends — so dot-vote's own clock decides when: a house is played for
## [member LmConfig.house_minutes], and as the limit nears a ballot opens with every house on
## it, the current one included (`include_current`) and an extension (`include_extend`).
## The winner is played at once. Players can rock the vote (`!rtv`) at any time. An owner's
## own house is a directory of level documents, and appears on the ballot at the next boot.
##
## [b]Server side only[/b], like mg-deathrun's course vote: a client draws the ballot from the
## notice [member ballot_fn] sends.

const CHANNEL := "lookatme.vote"

## The key in the running game's descriptor metadata an operator's overrides are read from —
## [code]metadata: house_vote:[/code] in a delivered game's [code]game.yml[/code].
const METADATA_KEY := "house_vote"

## What the vote command is called: `!vote 2` in chat, `vote 2` in a console.
const COMMAND_NAMES := {"vote": "vote"}

## Minutes a house is played before the ballot (LmConfig.house_minutes). 0: only rock the vote.
var house_minutes: float = 45.0

## The file a server owner configures the vote in, keyed exactly as [DotVoteRules]. Layered:
## [code]_rules() < game.yml metadata house_vote: < this file < DOT_VOTE_* < --vote-*[/code].
## Empty skips the file. [code]{"enabled": false}[/code] turns the vote off and the rotation
## stays on its house.
@export var config_path: String = "user://cfg/lookatme_vote.json"

## [code]func() -> Array[/code] of [code][id, name][/code] pairs: every house a ballot may offer.
var houses_fn: Callable = Callable()

## [code]func(id: StringName) -> DotResult[/code]: play this house now.
var apply_fn: Callable = Callable()

## [code]func() -> Array[/code] of voter ids (StringName): the people who may vote. Stand-ins
## are not voters — a ballot they could swing is not the players' choice.
var voters_fn: Callable = Callable()

## Says a line to everybody.
var announce_fn: Callable = Callable()

## Whether a voter is an admin, for dot-vote's admin bypasses.
var is_admin_fn: Callable = Callable()

## [code]func(state: Dictionary)[/code]: the ballot as a client draws it, sent when it changes.
var ballot_fn: Callable = Callable()

## [code]func(voter: StringName) -> Dictionary[/code]: a voter's name and avatar, for the ballot.
var people_fn: Callable = Callable()

var director: DotVoteDirector = null
var source: DotVoteListSource = null
var commands: DotVoteCommands = null
var feed: DotVoteBallotFeed = null



## Builds the director. Fails when the rules do not validate, never because there are too few
## houses: a server that gains one gets a ballot with it from the next refresh.
func setup() -> DotResult:
	source = DotVoteListSource.new()
	source.label = "houses"
	source.apply_fn = func(id: StringName) -> DotResult:
		return apply_fn.call(id) if apply_fn.is_valid() else DotResult.success(id)
	refresh_houses()

	director = DotVoteDirector.new()
	director.name = "VoteDirector"
	director.rules = configured_rules()
	director.source = source
	director.auto_apply = true
	# The host calls begin() whenever a house opens, which a vote's change is one cause of
	# and an operator's lm_house another; both firing would put one play in the
	# history twice. See DotVoteDirector.begin_on_apply.
	director.begin_on_apply = false
	# The server's tick drives it, not the frame clock.
	director.self_advance = false
	director.round_based = false

	director.player_count_fn = func() -> int:
		return _voters().size()
	director.voters_fn = _voters
	director.is_admin_fn = func(voter: StringName) -> bool:
		return is_admin_fn.is_valid() and bool(is_admin_fn.call(voter))
	director.announce_fn = func(line: String) -> void:
		if announce_fn.is_valid():
			announce_fn.call(line)

	add_child(director)

	director.vote_closed.connect(func(result: DotVoteResult) -> void:
		DotLog.info(CHANNEL, "the house vote closed", {"winner": String(result.winner_id), "votes": result.votes_cast})
	)

	feed = DotVoteBallotFeed.of(director, func(state: Dictionary) -> void:
		if ballot_fn.is_valid():
			ballot_fn.call(state)
	)
	feed.title = "Vote for the next house"
	feed.command = COMMAND_NAMES["vote"]
	feed.people_fn = func(voter: StringName) -> Dictionary:
		return people_fn.call(voter) if people_fn.is_valid() else {}

	return DotResult.success(self)


## [method _rules] under the server owner's layers. A layer that does not validate is refused
## whole, with the reason logged, and the defaults stand.
func configured_rules() -> DotVoteRules:
	var rules := _rules()
	var loaded := rules.layer_over_defaults(
		config_path, DotVoteGameSource.running_game_metadata(METADATA_KEY)
	)
	DotLog.result(CHANNEL, "the house vote's rules", loaded)
	return rules


## What a server that never ends wants from dot-vote by default. Every line is a default an
## operator overrides in [member config_path].
func _rules() -> DotVoteRules:
	var rules := DotVoteRules.new()

	if house_minutes > 0.0:
		rules.trigger = DotVoteRules.Trigger.TIME_LIMIT
		rules.duration_sec = house_minutes * 60.0
	else:
		rules.trigger = DotVoteRules.Trigger.RTV_ONLY
		rules.duration_sec = 0.0

	# At once: there is no round to wait for, and everybody is sent to the new lobby anyway.
	rules.apply = DotVoteRules.Apply.IMMEDIATE
	rules.rtv_apply = DotVoteRules.Apply.IMMEDIATE
	rules.include_current = true
	rules.include_extend = true
	rules.cooldown = 0
	rules.max_options = 6
	rules.vote_duration_sec = 30.0
	rules.method = DotVoteRules.Method.PLURALITY
	rules.tie_break = DotVoteRules.TieBreak.RANDOM
	return rules


## Reads the house list again: on boot, and after one is added.
func refresh_houses() -> void:
	if source == null:
		return

	source.entries.clear()

	if not houses_fn.is_valid():
		return

	for pair: Variant in houses_fn.call():
		var row: Array = pair
		var _added := source.add(DotVoteChoice.of(StringName(str(row[0])), str(row[1])))


## A house opened (by the vote or an operator): the director's clock starts over on it.
func note_house(id: StringName) -> void:
	if director == null:
		return

	source.current = id
	director.begin(id)


## One tick: dot-vote's clock opens the ballot when the house's time is nearly up.
func advance(delta: float) -> void:
	if director == null:
		return

	director.advance(delta)

	if feed != null:
		feed.poll()


func forget_voter(voter: StringName) -> void:
	if director != null:
		director.forget_voter(voter)


func is_voting() -> bool:
	return director != null and director.is_voting()


## dot-vote's commands on [param host]: `vote`, `rtv`, `nominate` and the operator's. Voters
## are the bare session id, the same spelling [member voters_fn] lists — dot-vote's default is
## `u<userid>`, and two spellings of one voter is a player who rocks the vote twice.
func install_commands(host: Object) -> DotResult:
	if director == null:
		return DotResult.fail(DotError.CODE_STATE, "There is no vote to command.")

	commands = DotVoteCommands.new()
	commands.director = director
	commands.names = COMMAND_NAMES
	commands.voter_fn = func(ctx: Object) -> StringName:
		var session: Variant = ctx.get("session")

		if session is Object and (session as Object).get("userid") != null:
			return StringName(str((session as Object).get("userid")))

		return &"console"

	var bound := commands.bind(host)

	if feed != null:
		feed.command = commands.command_name("vote")

	return bound


func _voters() -> Array:
	return voters_fn.call() if voters_fn.is_valid() else []


func describe() -> Dictionary:
	return {
		"houses": source.entries.size() if source != null else 0,
		"house_minutes": house_minutes,
		"director": director.describe() if director != null else {},
	}


func describe_lines() -> PackedStringArray:
	return director.describe_lines() if director != null else PackedStringArray()
