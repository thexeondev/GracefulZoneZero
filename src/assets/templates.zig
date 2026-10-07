pub const AvatarConfigTemplate = struct {
    pub const items: []const AvatarConfigTemplate =
        @import("assets/templatetb/AvatarConfigTemplateTb.zon");

    id: u32,
    code_name: []const u8,
    name: []const u8,
    full_name: []const u8,
    audio_event_replace_param: []const u8,
    audio_bank: []const u8,
};

pub const UnlockConfigTemplate = struct {
    pub const items: []const UnlockConfigTemplate =
        @import("assets/templatetb/UnlockConfigTemplateTb.zon");

    id: u31,
    lock_type: u32,
    lock_param: []const u8,
    unlock_type: u32,
    unlock_hint: []const u8,
    menu_type: u32,
    icon_res: []const u8,
};

pub const TeleportConfigTemplate = struct {
    pub const items: []const TeleportConfigTemplate =
        @import("assets/templatetb/TeleportConfigTemplateTb.zon");

    id: u31,
    unlock_condition: []const u8,
    teleport_name: []const u8,
    icon_path: []const u8,
    teleport_section: u32,
    teleport_transform: []const u8,
};
