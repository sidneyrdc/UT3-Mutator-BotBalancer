class BotBalancerMutator extends UTMutator;

// support for in-game logging in this class
`include( .\BotBalancer\Classes\BotBalancerLogger.uci );

`if(`notdefined(FINAL_RELEASE))
	var bool bShowDebug;
	var bool bShowDebugCheckReplacement;

	var bool bDebugSwitchToSpectator;
	var bool bDebugGiveInventory;
`endif

//**********************************************************************************
// Constant variables
//**********************************************************************************

var() const byte DEFAULT_TEAM_UNSET;
var() const byte DEFAULT_TEAM_BOT;
var() const byte DEFAULT_TEAM_PLAYER;

//**********************************************************************************
// Workflow variables
//**********************************************************************************

/** Set when GRI is initialized */
var bool bGRIInitialized;

/** Single instanced config instance which holds all the config variables */
var BotBalancerConfig MyConfig;

/** Readonly. Set when match has started (MatchStarting was called) */
var bool bMatchStarted;

var bool bForceDesiredPlayerCount;
var int DesiredPlayerCount;

var bool bOriginalForceAllRed;
var bool bIsOriginalForceAllRedSet;

var private UTTeamGame CacheGame;
var private class<UTBot> CacheBotClass;
var private array<UTBot> BotsWaitForRespawn;
var private array<PlayerController> PlayersWaitForChangeTeam;
var private array<PlayerController> PlayersWaitForRequestTeam;
var private array<UTBot> BotsSetOrders;

/** Used to track down spawned bots within the custom addbots code */
var private array<UTBot> BotsSpawnedOnce;

var BotBalancerGameRules ScoreHandler;

// ---=== Override config ===---

var bool bPlayersBalanceTeams;
var bool PlayersVsBots;
var float BotRatio;

/** Team index. Always valid index to GRI.Teams. Never 255/unset */
var byte PlayersSide;

/** Set if custom bot class has been replaced */
var bool bCustomBotClassReplaced;

//**********************************************************************************
// State for GRI initialization
//**********************************************************************************

auto state InitGRI
{
	function NotifyLogin(Controller NewPlayer)
	{
		// GRI related initialization
		SetGRI(WorldInfo.GRI);
		
		global.NotifyLogin(NewPlayer);
	}
	
	function bool AllowChangeTeam(Controller Other, out int num, bool bNewTeam)
	{
		// GRI related initialization
		SetGRI(WorldInfo.GRI);

		return global.AllowChangeTeam(Other, num, bNewTeam);
	}
}

//**********************************************************************************
// Inherited functions
//**********************************************************************************

`if(`notdefined(FINAL_RELEASE))
//
// Called immediately before gameplay begins.
//
event PreBeginPlay()
{
	`Log(name$"::PreBeginPlay",bShowDebug,'BotBalancer');
	super.PreBeginPlay();
}
`endif

// Called immediately after gameplay begins.
event PostBeginPlay()
{
	`Log(name$"::PostBeginPlay",bShowDebug,'BotBalancer');
	super.PostBeginPlay();

	CacheGame = UTTeamGame(WorldInfo.Game);
	if (CacheGame == none) //@TODO: destroy in Duel Game
	{
		`Warn(name$"::InitMutator - No team game. Destroy mutator!!!",bShowDebug,'BotBalancer');
		Destroy();
		return;
	}

	InitConfig();

	// Game rules for notify events of scores and kills
	CreateGameRules();

	// set bot class to a null class (abstract) which prevents
	// bots being spawned by commands like (addbots, addbluebots,...)
	// but also timed by NeedPlayers in GameInfo::Timer
	CacheBotClass = CacheGame.BotClass;
	CacheGame.BotClass = class'BotBalancerNullBot';

	// Disable auto balancing of bot teams.
	CacheGame.bCustomBots = true;
}

event Destroyed()
{
	`Log(name$"::Destroyed",bShowDebug,'BotBalancer');
	
	if (ScoreHandler != none)
	{
		ScoreHandler.Destroy();
		ScoreHandler = none;
	}

	MyConfig = none;
	super.Destroyed();
}

function bool MutatorIsAllowed()
{
	`Log(name$"::MutatorIsAllowed",bShowDebug,'BotBalancer');
	`Log(name$"::MutatorIsAllowed - Return:"@(UTTeamGame(WorldInfo.Game) != None && UTDuelGame(WorldInfo.Game) == None && Super.MutatorIsAllowed()),bShowDebug,'BotBalancer');

	//only allow mutator in Team games (except Duel)
	return UTTeamGame(WorldInfo.Game) != None && UTDuelGame(WorldInfo.Game) == None && Super.MutatorIsAllowed();
}

function InitMutator(string Options, out string ErrorMessage)
{
	local string InOpt;

	`Log(name$"::InitMutator - Options:"@Options,bShowDebug,'BotBalancer');
	super.InitMutator(Options, ErrorMessage);

	// override player-balance flag
	if (class'GameInfo'.static.HasOption(Options, "BalanceTeams"))
	{
		InOpt = class'GameInfo'.static.ParseOption(Options, "BalanceTeams");
		bPlayersBalanceTeams = bool(InOpt);
	}
}

// overridden. but not called. called manually
function SetGRI(GameReplicationInfo GRI)
{
	`Log(name$"::SetGRI - GRI:"@GRI,bShowDebug,'BotBalancer');
	if (GRI == none || bGRIInitialized)
		return;

	`Log(name$"::SetGRI - Init GRi-related variables once:"@GRI,bShowDebug,'BotBalancer');

	if (MyConfig != none)
	{
		SetPlayersSide();
	}

	bGRIInitialized = true;
	GotoState('');
}

// called when gameplay actually starts
function MatchStarting()
{
	local string InOpt;

	`Log(name$"::MatchStarting",bShowDebug,'BotBalancer');
	super.MatchStarting();

	if (CacheGame == none)
	{
		`Warn(name$"::MatchStarting - No cached game. Abort",bShowDebug,'BotBalancer');
		return;
	}

	if (MyConfig.UseLevelRecommendation)
	{
		CacheGame.bAutoNumBots = true;
		DesiredPlayerCount = CacheGame.LevelRecommendedPlayers();
		DesiredPlayerCount *= MyConfig.LevelRecommendationMultiplier;
		DesiredPlayerCount += MyConfig.LevelRecommendationOffsetPost;
		DesiredPlayerCount = Max(DesiredPlayerCount, 0);
		bForceDesiredPlayerCount = true;
	}
	else if (CacheGame.HasOption(CacheGame.ServerOptions, "NumPlay"))
	{
		// clear desired player count which then uses
		// the Game's desired value in the next timer
		DesiredPlayerCount = -1;
	}
	else
	{
		// just cache desired player count, also prevents adding bots at start
		DesiredPlayerCount = CacheGame.DesiredPlayerCount;
	}

	// override player-vs-bots vars
	if (class'GameInfo'.static.HasOption(CacheGame.ServerOptions, "VsBots"))
	{
		InOpt = class'GameInfo'.static.ParseOption(CacheGame.ServerOptions, "VsBots");
		if (InOpt ~= "false" || InOpt ~= "true")
		{
			PlayersVsBots = bool(InOpt);
		}
		else if (float(InOpt) > 0.0)
		{
			PlayersVsBots = true;
			BotRatio = float(InOpt);
		}
	}

	// override ratio var
	if (class'GameInfo'.static.HasOption(CacheGame.ServerOptions, "BotRatio"))
	{
		InOpt = class'GameInfo'.static.ParseOption(CacheGame.ServerOptions, "BotRatio");
		BotRatio = float(InOpt);
	}

	// if another mutator changes bots, store original one and
	// ensure we are using the NullBot for proper balancing
	if (CacheGame.BotClass != class'BotBalancerNullBot')
	{
		CacheBotClass = CacheGame.BotClass;
		CacheGame.BotClass = class'BotBalancerNullBot';
		bCustomBotClassReplaced = true;
	}

	bMatchStarted = true;
	SetTimer(1.0, true, 'TimerCheckPlayerCount');
}

`if(`notdefined(FINAL_RELEASE))
function ModifyLogin(out string Portal, out string Options)
{
	`Log(name$"::ModifyLogin - Portal:"@Portal$" - Options:"@Options,bShowDebug,'BotBalancer');
	super.ModifyLogin(Portal, Options);
}

function NotifyLogin(Controller NewPlayer)
{
	local PlayerController PC;

	`Log(name$"::NotifyLogin - NewPlayer:"@NewPlayer,bShowDebug,'BotBalancer');
	super.NotifyLogin(NewPlayer);

	PC = PlayerController(NewPlayer);
	if (PC != none && PC.bIsPlayer && PC.PlayerReplicationInfo != none)
	{
		if (bDebugSwitchToSpectator && PC.IsLocalPlayerController())
		{
			PC.PlayerReplicationInfo.bIsSpectator = true;
			PC.PlayerReplicationInfo.bOnlySpectator = true;
			PC.PlayerReplicationInfo.bOutOfLives = true;

			if (UTPlayerController(PC) != none)
			{
				UTPlayerController(PC).ServerSpectate();
				PC.ClientGotoState('Spectating');
			}
			else
			{
				PC.GotoState('Spectating');
				PC.ClientGotoState('Spectating');
			}

			PC.UpdateURL("SpectatorOnly", "1", false);
		}
	}
}
`endif

function NotifyLogout(Controller Exiting)
{
	`Log(name$"::NotifyLogout - Exiting:"@Exiting,bShowDebug,'BotBalancer');
	super.NotifyLogout(Exiting);

	// abort balancing/etc. if listen player leaves game (by closing server / quitting game)
	if (WorldInfo.NetMode != NM_DedicatedServer && CacheGame.NumPlayers < 1 && CacheGame.NumTravellingPlayers < 1 && 
		UTPlayerController(Exiting) != none && UTPlayerController(Exiting).bQuittingToMainMenu)
	{
		return;
	}

	BotsSpawnedOnce.RemoveItem(UTBot(Exiting));

	if (bMatchStarted && UTBot(Exiting) == none)
	{
		BalanceBotsTeams();
	}
}

/* called by GameInfo.RestartPlayer()
	change the players jumpz, etc. here
*/
function ModifyPlayer(Pawn Other)
{
	local UTBot bot;
	local BotBalancerHelperPawnDeath pd;

	`Log(name$"::ModifyPlayer - Other:"@Other,bShowDebug,'BotBalancer');
	super.ModifyPlayer(Other);

`if(`notdefined(FINAL_RELEASE))
	if (bDebugGiveInventory && Other.Controller != none && AIController(Other.Controller) == none)
	{
		GiveInventory(Other, class'BotBalancerTestInventory');
	}
`endif

	if (Other == none || UTBot(Other.Controller) == none) return;
	bot = UTBot(Other.Controller);

	`Log(name$"::ModifyPlayer - Bot spawned...",bShowDebug,'BotBalancer');
	foreach Other.BasedActors(class'BotBalancerHelperPawnDeath', pd)
		break;

	if (pd == none)
	{
		`Log(name$"::ModifyPlayer - Attach helper for"@Other$"("$bot$")",bShowDebug,'BotBalancer');
	
		// attach helper which trigger events for death. this is used to revert bSpawnedByKismet and set bForceAllRed
		pd = Other.Spawn(class'BotBalancerHelperPawnDeath');
		pd.SetPlayerDeathDelegate(OnBotDeath_PreCheck, OnBotDeath_PostCheck);
		pd.SetBase(Other);
	}

	// prevents from calling TooManyBots whenever the bot idles
	// (and also from checking for too many bots or unbalanced teams)
	bot.bSpawnedByKismet = true;

	
	if (BotsWaitForRespawn.Length > 0)
	{
		// remove spawning bot from array
		BotsWaitForRespawn.RemoveItem(bot);
		// also remove invalid references, just in case
		BotsWaitForRespawn.RemoveItem(none);

		// cache bot to re-set orders
		BotsSetOrders.AddItem(bot);

		// revert to original if all bots respawned (at least once)
		if (BotsWaitForRespawn.Length < 1)
		{
			`Log(name$"::ModifyPlayer - All bots respawned. Re-set orders",bShowDebug,'BotBalancer');
			SemaForceAllRed(false);

			// re-set all bot orders for spawned bots
			ResetBotOrders(BotsSetOrders);

			// clear cache as all orders are set
			BotsSetOrders.Length = 0;
		}
	}

	// add bots to array of spawned bots
	if (BotsSpawnedOnce.Find(bot) == INDEX_NONE)
	{
		BotsSpawnedOnce.AddItem(bot);
	}
}

function bool AllowChangeTeam(Controller Other, out int num, bool bNewTeam)
{
	local bool ret;
	local PlayerController PC;
	local BotBalancerTimerHelper parmtimer;

	`Log(name$"::AllowChangeTeam - Other:"@Other$" - num:"@num$" - bNewTeam:"@bNewTeam,bShowDebug,'BotBalancer');
	ret = super.AllowChangeTeam(Other, num, bNewTeam);
	PC = PlayerController(Other);
	if (ret)
	{
		// disallow changing team if PlayersVsBots is set (but only if not a spectator)
		if (PlayersVsBots && !MyConfig.AllowTeamChangeVsBots && PC != none && 
			bNewTeam && num != PlayersSide && Other.PlayerReplicationInfo != none && !Other.PlayerReplicationInfo.bOnlySpectator)
		{
			`Log(name$"::AllowChangeTeam - No allowed in Vs-Bots mode",bShowDebug,'BotBalancer');

			//@TODO: add support for Multi-Team
			PC.ReceiveLocalizedMessage(class'UTTeamGameMessage', PlayersSide == 0 ? 1 : 2);
			return false;
		}
	}

	`Log(name$"::AllowChangeTeam - ChangeTeam allowed at first. No find team index...",bShowDebug,'BotBalancer');

	// Note 1: clear forced flag to allow team change for players
	// Note 2: players connected as players and entering midgame (becomeactive) do call
	//         AllowBecomeActivePlayer before AllowChangeTeam is called. At this time
	//         these players already have bOnlySpectator unset (UTPlayerController::ServerBecomeActivePlayer).
	//         For this case, the mutator stores a requesting player into an array which is queried for now which
	//         then represents a valid BecomeActivePlayer procedure
	if (PC != none && (bNewTeam || PlayersWaitForRequestTeam.Find(PC) != INDEX_NONE))
	{
		`Log(name$"::AllowChangeTeam - Allow team change temp.",bShowDebug,'BotBalancer');

		// remove changing player from array
		PlayersWaitForRequestTeam.RemoveItem(PC);
		// also remove invalid references, just in case
		PlayersWaitForRequestTeam.RemoveItem(none);

		SemaForceAllRed(true);
		CacheGame.bForceAllRed = false;

		PlayersWaitForChangeTeam.AddItem(PC);

		// as other mutators can disallow changing, we need to remove this PC from PlayersWaitForChangeTeam
		// we call a parameterized timer the next tick which removes that player from the array
		parmtimer = new class'BotBalancerTimerHelper';
		parmtimer.PC = PC;
		parmtimer.Callback = self;
		SetTimer(0.001, false, 'TimedChangedTeam', parmtimer);
	}

	if (PlayersVsBots)
	{
		// spawning player/bot into the correct team
		if (!bNewTeam) 
		{
			num = GetNextTeamIndex(AIController(Other) != none);
		}
	}
	else if (bPlayersBalanceTeams && PC != none)
	{
		num = GetNextTeamIndex(false);
	}

	`Log(name$"::AllowChangeTeam - Return team:"@num,bShowDebug,'BotBalancer');
	return ret;
}

function NotifySetTeam(Controller Other, TeamInfo OldTeam, TeamInfo NewTeam, bool bNewTeam)
{
	`Log(name$"::NotifySetTeam - Other:"@Other$" - OldTeam:"@OldTeam$" - NewTeam:"@NewTeam$" - bNewTeam:"@bNewTeam,bShowDebug,'BotBalancer');
	super.NotifySetTeam(Other, OldTeam, NewTeam, bNewTeam);

	if (PlayerController(Other) != none && bNewTeam)
	{
		`Log(name$"::NotifySetTeam - New team set for player",bShowDebug,'BotBalancer');

		// remove swapped player from array
		PlayersWaitForChangeTeam.RemoveItem(PlayerController(Other));
		// also remove invalid references, just in case
		PlayersWaitForChangeTeam.RemoveItem(none);
	}

	CheckAndClearForceRedAll();

	if (bMatchStarted && UTBot(Other) == none)
	{
		BalanceBotsTeams();
	}
}

function bool AllowBecomeActivePlayer(PlayerController P)
{
	local bool ret;
	local BotBalancerTimerHelper parmtimer;

	`Log(name$"::AllowBecomeActivePlayer - P:"@P,bShowDebug,'BotBalancer');
	ret = super.AllowBecomeActivePlayer(P);

	if (ret && P != none)
	{
		`Log(name$"::AllowBecomeActivePlayer - From spec to player. Request added for check",bShowDebug,'BotBalancer');
		PlayersWaitForRequestTeam.AddItem(P);

		// as other mutators can disallow becoming active, we need to remove this PC from PlayersWaitForRequestTeam
		// we call a parameterized timer the next tick which removes that player from the array
		parmtimer = new class'BotBalancerTimerHelper';
		parmtimer.PC = P;
		parmtimer.Callback = self;
		SetTimer(0.001, false, 'TimedBecamePlayer', parmtimer);
	}

	return ret;
}

`if(`notdefined(FINAL_RELEASE))
function NotifyBecomeActivePlayer(PlayerController Player)
{
	`Log(name$"::NotifyBecomeActivePlayer - Player:"@Player,bShowDebug,'BotBalancer');
	super.NotifyBecomeActivePlayer(Player);
}
`endif

function NotifyBecomeSpectator(PlayerController Player)
{
	`Log(name$"::NotifyBecomeSpectator - Player:"@Player,bShowDebug,'BotBalancer');
	super.NotifyBecomeSpectator(Player);

	if (bMatchStarted)
	{
		BalanceBotsTeams();
	}
}

`if(`notdefined(FINAL_RELEASE))
function Mutate(string MutateString, PlayerController Sender)
{
	local string str, value, value2;
	local int i;
	local UTBot bot;
	local int Counts[2];

	`Log(name$"::Mutate - MutateString:"@MutateString$" - Sender:"@Sender,bShowDebug,'BotBalancer');
	super.Mutate(MutateString, Sender);

	if (Sender == none)
		return;

	str = "BB SwitchBot"; // BB SwitchBot FromTeam ToTeam
	if (Left(MutateString, Len(str)) ~= str)
	{
		value = Mid(MutateString, Len(str)+1); // FromTeam ToTeam
		i = InStr(value, " ");
		if (i != INDEX_NONE)
		{
			value2 = Mid(value, i+1); // ToTeam
			value = Left(value, i); // FromTeam

			if (int(value) < WorldInfo.GRI.Teams.Length && int(value2) < WorldInfo.GRI.Teams.Length)
			{
				if (GetRandomPlayerByTeam(WorldInfo.GRI.Teams[int(value)], bot))
				{
					SwitchBot(bot, int(value2));
					Sender.ClientMessage("Bot"@bot.GetHumanReadableName()@"switched");
				}
				else
				{
					Sender.ClientMessage("Unable to get random bot from team"@value);
				}
			}
			else
			{
				Sender.ClientMessage("Invalid team indizes");
			}
		}
		return;
	}

	str = "BB Spec"; // BB Switch
	if (Left(MutateString, Len(str)) ~= str)
	{
		if (GoToSpectator(Sender))
		{
			Sender.ClientMessage("Switched to spectator");
		}
		else
		{
			Sender.ClientMessage("Unable to switch to spectator");
		}
		return;
	}
	
	str = "BB CountTeams"; // BB CountTeams
	if (Left(MutateString, Len(str)) ~= str)
	{
		for (i=0;i<WorldInfo.GRI.PRIArray.Length;i++)
		{
			if (WorldInfo.GRI.PRIArray[i].Team != none && WorldInfo.GRI.PRIArray[i].Team.TeamIndex<2)
			{
				Counts[WorldInfo.GRI.PRIArray[i].Team.TeamIndex]++;
			}
		}

		Sender.ClientMessage("Team 0:"@Counts[0]$"  Team 1:"@Counts[1]);
		return;
	}

	str = "BB ListPlayers"; // BB CountTeams
	if (Left(MutateString, Len(str)) ~= str)
	{
		value = "";
		for (i=0;i<WorldInfo.GRI.PRIArray.Length;i++)
		{
			value $= WorldInfo.GRI.PRIArray[i].GetHumanReadableName()$" ("$WorldInfo.GRI.PRIArray[i]$")";
			value $= "\n";
		}

		Sender.ClientMessage(value);
		return;
	}
}

// Returns true to keep this actor
function bool CheckReplacement(Actor Other)
{
	`Log(name$"::CheckReplacement - Other:"@Other,bShowDebug&&bShowDebugCheckReplacement,'BotBalancer');
	return true;
}

`endif

//**********************************************************************************
// Events
//**********************************************************************************

event TimerCheckPlayerCount()
{
	if (CacheGame == none)
		ClearTimer();

	if (CacheGame.DesiredPlayerCount != DesiredPlayerCount)
	{
		if (bForceDesiredPlayerCount)
		{
			CacheGame.DesiredPlayerCount = DesiredPlayerCount;
			bForceDesiredPlayerCount = false;
		}

		// attempted to add bots through external code, use custom code now
		AddBots(CacheGame.DesiredPlayerCount);

		// clear player count again to stop throw error messages (due to timed NeedPlayers-call)
		DesiredPlayerCount = CacheGame.DesiredPlayerCount;
	}
}

event TimerChangedTeam(PlayerController PC)
{
	PlayersWaitForChangeTeam.RemoveItem(PC);
	CheckAndClearForceRedAll();
}

event TimerBecamePlayer(PlayerController PC)
{
	PlayersWaitForRequestTeam.RemoveItem(PC);
}

//**********************************************************************************
// Delegate callbacks
//**********************************************************************************

function OnBotDeath_PreCheck(Pawn Other, Object Sender)
{
	local Controller C;
	`log(name$"::OnBotDeath_PreCheck - Other:"@Other$" - Sender:"@Sender,bShowDebug,'BotBalancer');
	
	if (GetController(Other, C) && UTBot(C) != none)
	{
		`log(name$"::OnBotDeath_PreCheck - Clear vars",bShowDebug,'BotBalancer');

		// revert so bot spawns normally (and does not get destroyed)
		UTBot(C).bSpawnedByKismet = false;
		BotsWaitForRespawn.AddItem(UTBot(C));
	}

	// set bForceAllRed to bail out TooManyBots until Player respawned
	SemaForceAllRed(true);
	CacheGame.bForceAllRed = true;
}

//@TODO: remove? as it is unused
function OnBotDeath_PostCheck(Pawn Other, Actor Sender)
{
	`log(name$"::OnBotDeath_PostCheck - Other:"@Other$" - Sender:"@Sender,bShowDebug,'BotBalancer');
	//CacheGame.bForceAllRed = false;
}

function NotifyScoreObjective(PlayerReplicationInfo Scorer, Int Score)
{
	`Log(self$"::NotifyScoreObjective - Scorer:"@Scorer$" - Score:"@Score,bShowDebug,'BotBalancer');

}

function NotifyScoreKill(Controller Killer, Controller Killed)
{
	`Log(self$"::NotifyScoreKill - Killer:"@Killer$" - Killed:"@Killed,bShowDebug,'BotBalancer');
 
	if (MyConfig.AdjustBotSkill)
	{
		switch (MyConfig.SkillAdjustment)
		{
		case Algo_Original:
			// adjust bot skills to match player 
			if (Killer.IsA('PlayerController') && Killed.IsA('AIController'))
			{
				StockAdjustSkill(AIController(Killed), PlayerController(Killer), true);
			}
			else if (Killed.IsA('PlayerController') && Killer.IsA('AIController'))
			{
				StockAdjustSkill(AIController(Killer), PlayerController(Killed), false);
			}
			break;
		case Algo_Adjustable:
			if (Killer.IsA('PlayerController') && Killed.IsA('AIController'))
			{
				ConfigBasedAdjustSkill(AIController(Killed), PlayerController(Killer), true);
			}
			else if (Killed.IsA('PlayerController') && Killer.IsA('AIController'))
			{
				ConfigBasedAdjustSkill(AIController(Killer), PlayerController(Killed), false);
			}
			break;
		}
		
	}
}

/** Adjusts the bot skill
 * @param B the Bot to adjus skill
 * @param P the opponent player
 * @param bWinner wheher the player is the winner/killer (false means the bot has killed the player)
 **/
function StockAdjustSkill(AIController B, PlayerController P, bool bWinner)
{
	local float AdjustmentFactor;
	local array<int> PlayersCount, BotsCount;
	local array<float> TeamScore;
	local byte TeamIndexWinner, TeamIndexOther;
	local float AdjustedDifficulty;
	local int TeamIndex;

	// slightly adjust skill
	AdjustmentFactor = 0.15;

	// calc player/bot and team score arrays, returns the index of the larger team (or -1)
	TeamIndex = GetTeamPlayers(PlayersCount, BotsCount, TeamScore);

	AdjustedDifficulty = CacheGame.AdjustedDifficulty;

	if (bWinner)
	{
		TeamIndexWinner = P.GetTeamNum();
		TeamIndexOther = B.GetTeamNum();
		AdjustmentFactor = Abs(AdjustmentFactor);
	}
	else
	{
		TeamIndexWinner = B.GetTeamNum();
		TeamIndexOther = P.GetTeamNum();
		AdjustmentFactor = -1 * Abs(AdjustmentFactor);
	}

	// only adjust loser team if needed based on score
	if (TeamIndexWinner < TeamScore.Length && TeamIndexOther < TeamScore.Length &&
		(TeamScore[TeamIndexOther] - 1 < TeamScore[TeamIndexWinner]))
	{
		AdjustedDifficulty = FClamp(AdjustedDifficulty + AdjustmentFactor, 0.0, 7.0);
	}

	// adjust game difficulty
	AdjustedDifficulty = FClamp(AdjustedDifficulty, CacheGame.GameDifficulty - 1.25, CacheGame.GameDifficulty + 1.25);
	CacheGame.AdjustedDifficulty = AdjustedDifficulty;

	if (bWinner == (B.Skill < AdjustedDifficulty))
	{
		StockCampaignSkillAdjust(UTBot(B), TeamIndexWinner, TeamIndexOther);
		UTBot(B).ResetSkill();
	}
}

// mostly copied from original game code related to Story-mode
function StockCampaignSkillAdjust(UTBot aBot, int TeamIndexWinner, int TeamIndexOther)
{
	if ( (aBot.PlayerReplicationInfo.Team.TeamIndex == TeamIndexOther) || (CacheGame.AdjustedDifficulty < CacheGame.GameDifficulty) )
	{
		aBot.Skill = CacheGame.AdjustedDifficulty;

		if ( aBot.PlayerReplicationInfo.Team.TeamIndex == TeamIndexOther )
		{
			// reduced enemy skill slightly if their team is bigger
			if (CacheGame.Teams[TeamIndexOther].Size > CacheGame.Teams[TeamIndexWinner].size )
			{
				aBot.Skill -= 0.5;
			}
			else if ( (CacheGame.Teams[TeamIndexOther].Size < CacheGame.Teams[TeamIndexWinner].Size) && (CacheGame.NumPlayers > 1) )
			{
				aBot.Skill += 0.75;
			}

			// increase skill for the big bosses.
			if ( aBot.PlayerReplicationInfo.PlayerName ~= "Akasha" )
			{
				aBot.Skill += 1.5;
			}
			else if ( aBot.PlayerReplicationInfo.PlayerName ~= "Loque" )
			{
				aBot.Skill += 0.75;
			}
		}
	}
	else
	{
		aBot.Skill = 0.5 * (CacheGame.AdjustedDifficulty + CacheGame.GameDifficulty);
	}
}

/** Adjusts the bot skill based on config values
 * @param B the Bot to adjus skill
 * @param P the opponent player
 * @param bWinner wheher the player is the winner/killer (false means the bot has killed the player)
 **/
function ConfigBasedAdjustSkill(AIController B, PlayerController P, bool bWinner)
{
	local float AdjustmentFactor;
	local array<int> PlayersCount, BotsCount;
	local array<float> TeamScore;
	local byte TeamIndexWinner, TeamIndexOther;
	local float AdjustedDifficulty;
	local int TeamIndex;

	// slightly adjust skill
	AdjustmentFactor = MyConfig.SkillAdjustmentFactor;

	// calc player/bot and team score arrays, returns the index of the larger team (or -1)
	TeamIndex = GetTeamPlayers(PlayersCount, BotsCount, TeamScore);

	AdjustedDifficulty = CacheGame.AdjustedDifficulty;

	if (bWinner)
	{
		TeamIndexWinner = P.GetTeamNum();
		TeamIndexOther = B.GetTeamNum();
		AdjustmentFactor = Abs(AdjustmentFactor);
	}
	else
	{
		TeamIndexWinner = B.GetTeamNum();
		TeamIndexOther = P.GetTeamNum();
		AdjustmentFactor = -1 * Abs(AdjustmentFactor);
	}

	// only adjust loser team if needed based on score
	if (TeamIndexWinner < TeamScore.Length && TeamIndexOther < TeamScore.Length &&
		(TeamScore[TeamIndexOther] - MyConfig.SkillAdjustmentThreshold < TeamScore[TeamIndexWinner]))
	{
		AdjustedDifficulty += AdjustmentFactor;
	}

	// adjust game difficulty
	if (MyConfig.SkillAdjustmentDisparity > 0.0)
		AdjustedDifficulty = FClamp(AdjustedDifficulty, CacheGame.GameDifficulty - MyConfig.SkillAdjustmentDisparity, CacheGame.GameDifficulty + MyConfig.SkillAdjustmentDisparity);
	if (MyConfig.SkillAdjustmentMaxSkill > 0.0)
		AdjustedDifficulty = FMin(AdjustedDifficulty, MyConfig.SkillAdjustmentMaxSkill);
	if (MyConfig.SkillAdjustmentMinSkill >= 0.0)
		AdjustedDifficulty = FMax(AdjustedDifficulty, MyConfig.SkillAdjustmentMinSkill);

	// apply difficulty
	AdjustedDifficulty = FClamp(AdjustedDifficulty, 0.0, 7.0);
	CacheGame.AdjustedDifficulty = AdjustedDifficulty;

	if (bWinner == (B.Skill < AdjustedDifficulty))
	{
		if (MyConfig.SkillAdjustmentLikeCampaign)
			ConfigBasedCampaignSkillAdjust(UTBot(B), TeamIndexWinner, TeamIndexOther);
		UTBot(B).ResetSkill();
	}
}

function ConfigBasedCampaignSkillAdjust(UTBot aBot, int TeamIndexWinner, int TeamIndexOther)
{
	if ( (aBot.PlayerReplicationInfo.Team.TeamIndex == TeamIndexOther) || (CacheGame.AdjustedDifficulty < CacheGame.GameDifficulty) )
	{
		aBot.Skill = CacheGame.AdjustedDifficulty;

		if ( aBot.PlayerReplicationInfo.Team.TeamIndex == TeamIndexOther )
		{
			// reduced enemy skill slightly if their team is bigger
			if (CacheGame.Teams[TeamIndexOther].Size > CacheGame.Teams[TeamIndexWinner].Size )
			{
				aBot.Skill -= MyConfig.SkillAdjustmentCampaignReduce;
			}
			else if ( (CacheGame.Teams[TeamIndexOther].Size < CacheGame.Teams[TeamIndexWinner].Size) && (CacheGame.NumPlayers > 1) )
			{
				aBot.Skill += MyConfig.SkillAdjustmentCampaignIncrease;
			}

			// increase skill for the big bosses.
			if ( aBot.PlayerReplicationInfo.PlayerName ~= "Akasha" )
			{
				aBot.Skill += 1.5;
			}
			else if ( aBot.PlayerReplicationInfo.PlayerName ~= "Loque" )
			{
				aBot.Skill += 0.75;
			}
		}
	}
	else
	{
		aBot.Skill = 0.5 * (CacheGame.AdjustedDifficulty + CacheGame.GameDifficulty);
	}
}

//**********************************************************************************
// Private functions
//**********************************************************************************

function InitConfig()
{
	`log(name$"::InitConfig",bShowDebug,'BotBalancer');

	MyConfig = class'BotBalancerConfig'.static.GetConfig();
	MyConfig.Validate();

	MyConfig.SaveConfigCustom();
	`log(name$"::InitConfig - Config saved.",bShowDebug,'BotBalancer');

	// set runtime vars from config values
	bPlayersBalanceTeams = MyConfig.bPlayersBalanceTeams;
	PlayersVsBots = MyConfig.PlayersVsBots;
	BotRatio = MyConfig.BotRatio;

	// if GRI was already initialized, set PlayersSide again
	if (bGRIInitialized) SetPlayersSide();
}

function CreateGameRules()
{
	ScoreHandler = Spawn(class'BotBalancerGameRules');
	if (ScoreHandler != none)
	{
		if ( WorldInfo.Game.GameRulesModifiers == None )
			WorldInfo.Game.GameRulesModifiers = ScoreHandler;
		else
			WorldInfo.Game.GameRulesModifiers.AddGameRules(ScoreHandler);

		ScoreHandler.Callback = self;
	}
}

function SetPlayersSide()
{
	// set random team if desired
	if (MyConfig.PlayersSide < 0)
		PlayersSide = Rand(WorldInfo.GRI.Teams.Length);
	else if (MyConfig.PlayersSide < WorldInfo.GRI.Teams.Length)
		PlayersSide = MyConfig.PlayersSide;
	//else if (MyConfig.PlayersSide < DEFAULT_TEAM_UNSET)
	//	PlayersSide = DEFAULT_TEAM_PLAYER;
	else
		PlayersSide = DEFAULT_TEAM_PLAYER;
}

function int GetNextTeamIndex(bool bBot)
{
	local UTTeamInfo BotTeam;
	local name packagename;
	local bool bSwap;
	local int TeamIndex;

	local int i, index, prefer;
	local float count;
	local array<int> PlayersCount;
	local array<float> TeamsCount;
	
	if (PlayersVsBots && bBot)
	{
		// check if class is an official one (in which case it is always only 2 teams)
		packagename = CacheGame.class.GetPackageName();
		switch (packagename)
		{
		case 'UTGame':
		case 'UTGameContent':
		case 'UT3GoldGame':
			if (UTDuelGame(CacheGame) != none) // in case, but in general Duel isn't allowed to run this mutator
			{
				//@TODO: add support for Duel
				return 0;
			}

			// stock games use 2 teams as max
			return Clamp(1 - PlayersSide, 0, 1); // use opposite
			break;
		default:
			if (WorldInfo.GRI.Teams.Length == 1)
				return WorldInfo.GRI.Teams[0].TeamIndex;
			else if (WorldInfo.GRI.Teams.Length == 2)
				return Clamp(1 - PlayersSide, 0, 1);
			else if (WorldInfo.GRI.Teams.Length > 2)
			{
				// get team index from all teams but players team
				count = WorldInfo.GRI.Teams.Length;
				index = PlayersSide + Rand(count-1) % count;
				return index;
			}
		}
		
		return 255;
	}
	else if (PlayersVsBots)
	{
		// put net player into the given team
		return PlayersSide;
	}

	if (CacheGame != none)
	{
		if (GetAdjustedTeamPlayerCount(PlayersCount, TeamsCount))
		{
			count = MaxInt;
			prefer = 0;
			index = INDEX_NONE;
			if (!bBot && bPlayersBalanceTeams)
			{
				// find team with lowest real player count
				for ( i=0; i<PlayersCount.Length; i++)
				{
					if (PlayersCount[i] < count)
					{
						count = PlayersCount[i];
						index = i;
					}
				}
			}
			else
			{
				// find team with lowest calculated player count (prefer team with lower net players)
				for ( i=0; i<TeamsCount.Length; i++)
				{
					if (TeamsCount[i] < count || (TeamsCount[i] == count && PlayersCount[i] < prefer))
					{
						count = TeamsCount[i];
						prefer = PlayersCount[i];
						index = i;
					}
				}
			}

			// if a proper team could be found, use that team
			if (index != INDEX_NONE)
			{
				return index;
			}
		}

		// use original algorithm to find proper team index
		// to prevent using always the Red team, we swap that flag temporarily
		bSwap = CacheGame.bForceAllRed;
		CacheGame.bForceAllRed = false;
		
		// find the proper team index for the player
		if (bBot) BotTeam = CacheGame.GetBotTeam();
		if (BotTeam != none) TeamIndex = BotTeam.TeamIndex;
		else TeamIndex = CacheGame.PickTeam(0, none);

		CacheGame.bForceAllRed = bSwap;
		return TeamIndex;
	}

	// use random index if possible (otherwise unset team)
	return (WorldInfo.GRI != none ? Rand(WorldInfo.GRI.Teams.Length) : int(DEFAULT_TEAM_UNSET));
}

function AddBots(int InDesiredPlayerCount)
{
	local int TeamNum, OldBotCount;
	local UTBot bot;
	local array<UTBot> tempbots;

	OldBotCount = BotsSpawnedOnce.Length;

	// force TooManyBots fail out. it is called right on initial spawn for bots
	SemaForceAllRed(true);
	CacheGame.bForceAllRed = true;

	DesiredPlayerCount = Clamp(InDesiredPlayerCount, 1, 32);
	while (CacheGame.NumPlayers + CacheGame.NumBots < DesiredPlayerCount)
	{
		// restore Game's original bot class
		CacheGame.BotClass = CacheBotClass;

		// add bot to the specific team
		TeamNum = GetNextTeamIndex(true);
		bot = CacheGame.AddBot(,true,TeamNum);

		// revert to null class to preven adding bots;
		CacheGame.BotClass = class'BotBalancerNullBot';

		if (bot == none)
			break;
		
		tempbots.AddItem(bot);
		if (BotsSpawnedOnce.Find(bot) == INDEX_NONE)
		{
			BotsWaitForRespawn.AddItem(bot);
		}
	}

	// revert to original if not bot was added to array
	if (BotsWaitForRespawn.Length < 1)
	{
		SemaForceAllRed(false);
	}

	if (OldBotCount != BotsSpawnedOnce.Length && !CacheGame.bForceAllRed)
	{
		ResetBotOrders(tempbots);
	}
}

function ResetBotOrders(array<UTBot> bots)
{
	local UTBot bot;

	bots.RemoveItem(none);
	foreach bots(bot)
	{
		if (bot.PlayerReplicationInfo != none && UTTeamInfo(bot.PlayerReplicationInfo.Team) != none)
		{
			UTTeamInfo(bot.PlayerReplicationInfo.Team).SetBotOrders(bot);
		}
	}
}

function BalanceBotsTeams()
{
	local array<int> PlayersCount;
	local array<float> TeamsCount;
	local int i;
	local int LowestCount, LowestIndex;
	local int HighestCount, HighestIndex;
	local int SwitchCount, diff;
	local UTBot Bot;
	
	`log(name$"::BalanceBotsTeams",bShowDebug,'BotBalancer');
	if (GetAdjustedTeamPlayerCount(PlayersCount, TeamsCount))
	{
		// find team with lowest real player count (prefer team with lower net players)
		LowestCount = MaxInt;
		LowestIndex = INDEX_NONE;
		HighestCount = -1;
		HighestIndex = INDEX_NONE;
		for ( i=0; i<TeamsCount.Length; i++)
		{
			if (TeamsCount[i] < LowestCount)
			{
				LowestCount = TeamsCount[i];
				LowestIndex = i;
			}
			if (TeamsCount[i] > HighestCount)
			{
				HighestCount = TeamsCount[i];
				HighestIndex = i;
			}
		}

		if (LowestIndex != INDEX_NONE && HighestIndex != INDEX_NONE && HighestIndex != LowestIndex)
		{
			diff = HighestCount - LowestCount;
			if (diff > 1/* && Abs(PlayersCount[HighestIndex] - PlayersCount[LowestIndex]) > 1*/)
			{
				SwitchCount = Round(float(diff)/2.0 + 0.5);
			}
		}
	}

	`log(name$"::BalanceBotsTeams - Change bots count:"@SwitchCount,bShowDebug,'BotBalancer');
	for (i=0; i<SwitchCount; i++)
	{
		// change from highest to lowest team
		if (!GetRandomPlayerByTeam(WorldInfo.GRI.Teams[HighestIndex], bot))
		{
			`warn(name$"::BalanceBotsTeams - Unable to change bot for"@bot$". Abort...",bShowDebug,'BotBalancer');
			break;
		}

		SwitchBot(bot, LowestIndex);
	}
}

function SwitchBot(UTBot bot, int TeamNum)
{
	local TeamInfo OldTeam;

	OldTeam = bot.PlayerReplicationInfo.Team;
	SemaForceAllRed(true);
	CacheGame.bForceAllRed = false;
	if (CacheGame.ChangeTeam(bot, TeamNum, true) && CacheGame.bTeamGame && bot.PlayerReplicationInfo.Team != OldTeam)
	{
		if (bot.Pawn != None)
		{
			bot.Pawn.PlayerChangedTeam();
		}

		BotsWaitForRespawn.AddItem(bot);
	}
	else 
	{
		CheckAndClearForceRedAll();
	}
}

`if(`notdefined(FINAL_RELEASE))
function bool GoToSpectator( PlayerController PC )
{
	local UTGame G;

	`log(name$"::GoToSpectator - PC:"@PC,bShowDebug,'BotBalancer');

	if (WorldInfo.Game == none)
		return false;

	G = UTGame(WorldInfo.Game);

	if (G != none && G.BecomeSpectator(PC))
	{
		PC.PlayerReplicationInfo.bIsSpectator = true;
		PC.PlayerReplicationInfo.bOnlySpectator = true;
		PC.PlayerReplicationInfo.bOutOfLives = true;
		
		if ( PC.Pawn != None )
			PC.Pawn.Suicide();

		if (PC.PlayerReplicationInfo.Team != none)
		{
			PC.PlayerReplicationInfo.Team.RemoveFromTeam  (PC);
			PC.PlayerReplicationInfo.Team = None;
		}


		PC.GotoState('Spectating');
		PC.ClientGotoState('Spectating');
		//PC.ClientGotoState('Spectating', 'Begin'); Begin is not defined
		PC.Reset();
		PC.PlayerReplicationInfo.Reset();
		
		WorldInfo.Game.BroadcastLocalizedMessage( WorldInfo.Game.GameMessageClass, 14, PC.PlayerReplicationInfo );

		//// Already called in BecomeSpectator
		//if (WorldInfo.Game.BaseMutator != none)
		//	WorldInfo.Game.BaseMutator.NotifyBecomeSpectator(PC);

		//// Already called in BecomeSpectator
		//if (G.VoteCollector != none)
		//	G.VoteCollector.NotifyBecomeSpectator(UTPlayerController(PC));

		WorldInfo.Game.UpdateGameSettingsCounts();

		return true;
	}

	return false;
}
`endif

function bool GetRandomPlayerByTeam(TeamInfo team, out UTBot OutBot)
{
	local int i;
	local array<PlayerReplicationInfo> randoms;
	
	for ( i=0; i<WorldInfo.GRI.PRIArray.Length; i++ )
	{
		// check for team and ignore net players
		if (WorldInfo.GRI.PRIArray[i].Team != Team || !IsValidPlayer(WorldInfo.GRI.PRIArray[i], true, true))
			continue;

		randoms.AddItem(WorldInfo.GRI.PRIArray[i]);
	}

	if (randoms.Length > 0)
	{
		i = Rand(randoms.Length);
		OutBot = UTBot(randoms[i].Owner);
		return true;
	}

	return false;
}

function bool GetAdjustedTeamPlayerCount(out array<int> PlayersCount, out array<float> TeamsCount)
{
	local int i, index, count;

	// init team count array
	PlayersCount.Length = 0; // clear
	PlayersCount.Length = WorldInfo.GRI.Teams.Length;
	TeamsCount.Length = 0; // clear
	TeamsCount.Length = WorldInfo.GRI.Teams.Length;

	// count real-players
	for ( i=0; i<WorldInfo.GRI.PRIArray.Length; i++ )
	{
		// only count non-bots and non-players
		if (!IsValidPlayer(WorldInfo.GRI.PRIArray[i]))
			continue;

		// fill up array if needed
		index = WorldInfo.GRI.PRIArray[i].Team.TeamIndex;
		if (PlayersCount.Length <= index)
		{
			PlayersCount.Add(index-PlayersCount.Length+1);
		}

		PlayersCount[index]++;
	}

	// take botratio into account and calculate resulting player count
	for ( i=0; i<PlayersCount.Length; i++)
	{
		// get bot count from team size
		count = WorldInfo.GRI.Teams[i].Size - PlayersCount[i];

		// use botratio to know how many proper player a team would have
		TeamsCount[i] = float(PlayersCount[i])*BotRatio + float(count);
	}

	return true;
}

/** Retrieves the player/bot count array (optionally returns team score array). 
 * @return the index of the greater team (-1 = equal, 255 = no team)
 */
function int GetTeamPlayers(out array<int> PlayersCount, out array<int> BotsCount, optional out array<float> TeamScore)
{
	local int i, index;
	local byte bIsBot;

	// init team count array
	PlayersCount.Length = 0; // clear
	PlayersCount.Length = WorldInfo.GRI.Teams.Length;
	BotsCount.Length = 0; // clear
	BotsCount.Length = WorldInfo.GRI.Teams.Length;

	TeamScore.Length = 0; // clear
	TeamScore.Length = WorldInfo.GRI.Teams.Length;

	// count real-players
	for ( i=0; i<WorldInfo.GRI.PRIArray.Length; i++ )
	{
		// only count real-players (bot and players)
		if (!IsValidPlayer(WorldInfo.GRI.PRIArray[i], true, false, bIsBot))
			continue;

		// fill up array if needed
		index = WorldInfo.GRI.PRIArray[i].Team.TeamIndex;

		// one up for the current out array
		if (bIsBot == 1)
		{
			if (BotsCount.Length <= index)
			{
				BotsCount.Length = index-BotsCount.Length+1;
			}

			BotsCount[index]++;
		}
		else
		{
			if (PlayersCount.Length <= index)
			{
				PlayersCount.Length = index-PlayersCount.Length+1;
			}

			PlayersCount[index]++;
		}
	}

	// set/count score of all teams
	for ( i=0; i<WorldInfo.GRI.Teams.Length; i++)
	{
		if (WorldInfo.GRI.Teams[i] == none) continue;
		TeamScore[i] = WorldInfo.GRI.Teams[i].Score;
	}

	if (TeamScore.Length == 0) 
	{
		return DEFAULT_TEAM_UNSET;
	}
	else if (TeamScore.Length == 1)
	{
		return 0;
	}
	else
	{
		// TODO: Add support for multi teams
		if (PlayersCount[0] == PlayersCount[1])
		{
			return -1;
		}
		
		// return greater team based on net-player count
		return PlayersCount[0] > PlayersCount[1] ? 1 : 0;
	}
}

private function SemaForceAllRed(bool bSet)
{
	if (bSet && !bIsOriginalForceAllRedSet)
	{
		bIsOriginalForceAllRedSet = true;
		bOriginalForceAllRed = CacheGame.bForceAllRed;
	}
	else if (!bSet && bIsOriginalForceAllRedSet)
	{
		bIsOriginalForceAllRedSet = false;
		CacheGame.bForceAllRed = bOriginalForceAllRed;
	}
}

private function CheckAndClearForceRedAll()
{
	if (BotsWaitForRespawn.Length < 1 && PlayersWaitForChangeTeam.Length < 1)
	{
		SemaForceAllRed(false);
	}
}

`if(`notdefined(FINAL_RELEASE))
function GiveInventory(Pawn Other, class<Inventory> ThisInventoryClass)
{
	if (Other == none || ThisInventoryClass == none)
	{
		return;
	}

	Other.CreateInventory(ThisInventoryClass, false);
}
`endif

//**********************************************************************************
// Helper functions
//**********************************************************************************

/** Returns whether the given player is a valid player (no spectator, valid team, etc.).
 *  By default, only net players are taken into account
 *  @param PRI the net player (or bot) to check
 *  @param bCheckBot whether to ignore bots
 *  @param bIsBot (out) outputs whether the given player is a bot (1 == true, else == false)
 *  @param bStrictBot if set, the player flag @ref <bIsBot> (bIsBot) is only true if the player is type UTBot and subclasses
 */
function bool IsValidPlayer(PlayerReplicationInfo PRI, optional bool bCheckBot, optional bool bOnlyBots, optional out byte bIsBot, optional bool bStrictBot)
{
	if (PRI == none || PRI.bOnlySpectator || (!bCheckBot && PRI.bBot) || PRI.Team == none || 
		PRI.Owner == none || (bOnlyBots && UTBot(PRI.Owner) == none))
		return false;

	bIsBot = (PRI.bBot && (!bStrictBot || UTBot(PRI.Owner) != none)) ? 1 : 0;
	return true;
}

function bool GetController(Pawn P, out Controller C)
{
	if (P == none)
		return false;

	C = P.Controller;
	if (C == None && P.DrivenVehicle != None)
	{
		C = P.DrivenVehicle.Controller;
	}

	return C != none;
}

DefaultProperties
{
	`if(`notdefined(FINAL_RELEASE))
		bShowDebug=true
		bShowDebugCheckReplacement=true
		bDebugSwitchToSpectator=false
		bDebugGiveInventory=true
	`endif

	DEFAULT_TEAM_BOT=1
	DEFAULT_TEAM_PLAYER=0
	DEFAULT_TEAM_UNSET=255
}
