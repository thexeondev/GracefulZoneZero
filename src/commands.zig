const grace = @import("grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

const namespaces: []const type = &.{
    @import("commands/player.zig"), // CmdPlayerType [0..99]
    @import("commands/mail.zig"), // CmdMailType [200..299]
    @import("commands/world.zig"), // CmdWorldType [400..549]
    @import("commands/quest.zig"), // CmdQuestType [550..699]
    @import("commands/item.zig"), // CmdItemType [700..799]
    @import("commands/avatar.zig"), // CmdAvatarType [800..849]
    @import("commands/buddy.zig"), // CmdBuddyType [850..899]
    @import("commands/gacha.zig"), // CmdGachaType [1000..1049]
    @import("commands/ramen.zig"), // CmdRamenType [1150..1249]
    @import("commands/misc.zig"), // CmdMiscType [1300..1399]
    @import("commands/monster_card.zig"), // CmdMonsterCardType [1450..1499]
    @import("commands/tips.zig"), // CmdTipsType [1600..1619]
    @import("commands/activity.zig"), // CmdActivityType [1700..1899]
    @import("commands/cafe.zig"), // CmdCafeType [1900..1949]
    @import("commands/land_revive.zig"), // CmdLandReviveType [1950..1999]
    @import("commands/partner_trust.zig"), // CmdPartnerTrustType [2000..2049]
    @import("commands/work_bench.zig"), // CmdWorkBenchType [2050..2099]
    @import("commands/reward_buff.zig"), // CmdRewardBuffType [2200..2219]
    @import("commands/arcade.zig"), // CmdArcadeType [2220..2399]
    @import("commands/training.zig"), // CmdTrainingType [2400..2449]
    @import("commands/embattles.zig"), // CmdEmbattlesType [2450..2499]
    @import("commands/vhs_store.zig"), // CmdVhsStoreType [2500..2549]
};

const HandlerFn = *const fn (*Session) Session.Error!void;

const cmd_count: usize = 10_000;
const handlers: *const [cmd_count]?HandlerFn = handlers: {
    var array: [cmd_count]?HandlerFn = @splat(null);
    for (namespaces) |namespace| {
        for (@typeInfo(namespace).@"struct".decl_names) |decl_name| {
            const cmd_id = @field(protobuf.gen, decl_name).cmd_id;
            if (array[cmd_id] != null) @compileError("duplicated handler for " ++ decl_name);
            array[cmd_id] = &@field(namespace, decl_name);
        }
    }

    const final = array;
    break :handlers &final;
};

pub const ExecuteError = Session.Error || error{
    CommandIdIllegal,
    CommandUnhandled,
};

pub fn execute(session: *Session) ExecuteError!void {
    if (session.command.id >= cmd_count) return error.CommandIdIllegal;
    const handlerFn = handlers[session.command.id] orelse return error.CommandUnhandled;
    try handlerFn(session);
}
