const std = @import("std");
const zm = @import("zmath");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const Handle = @import("../engine/resource.zig").Handle;
const AnimationInstance = @import("../geometry/animation.zig").AnimationInstance;

/// Transform component for nodes
pub const Transform = struct {
    position: zm.Vec = zm.f32x4s(0.0),
    rotation: zm.Quat = zm.qidentity(),
    scale: zm.Vec = zm.f32x4s(1.0),
    is_dirty: bool = false,
    local_matrix: zm.Mat = zm.identity(),
    world_matrix: zm.Mat = zm.identity(),
    pub fn toMatrix(self: *const Transform) zm.Mat {
        return zm.mul(zm.mul(zm.matFromQuat(self.rotation), zm.translationV(self.position)), zm.scalingV(self.scale));
    }
};
/// Scene node
pub const Node = struct {
    parent: Handle,
    children: ArrayList(Handle),
    allocator: Allocator,
    transform: Transform,
    data: union(enum) {
        light: Handle,
        skeletal_mesh: struct {
            handle: Handle,
            animation: AnimationInstance,
        },
        static_mesh: Handle,
        none,
    },

    pub fn init(self: *Node, allocator: Allocator) void {
        self.children = ArrayList(Handle).init(allocator);
        self.allocator = allocator;
        self.transform = .{};
    }

    pub fn deinit(self: *Node) void {
        self.children.deinit();
    }
};

/// Node pool methods for managing the parent-child hierarchy
pub fn unparentNode(pool: anytype, node: Handle) void {
    const child_node = pool.get(node) orelse return;
    const parent_handle = child_node.parent;

    // If no parent or parent is self, nothing to do
    if (parent_handle.index == 0 or (parent_handle.index == node.index and parent_handle.generation == node.generation)) {
        return;
    }

    const parent_node = pool.get(parent_handle) orelse return;
    if (parent_node == child_node) return;

    // Find and remove child from parent's children
    for (parent_node.children.items, 0..) |child, i| {
        if (child.index == node.index and child.generation == node.generation) {
            // Replace with last item and pop
            if (i < parent_node.children.items.len - 1) {
                parent_node.children.items[i] = parent_node.children.items[parent_node.children.items.len - 1];
            }
            _ = parent_node.children.pop();
            break;
        }
    }

    // Set node's parent to itself (no parent)
    child_node.parent = node;
}

pub fn parentNode(pool: anytype, parent: Handle, child: Handle) void {
    // First unparent the child
    unparentNode(pool, child);

    const parent_node = pool.get(parent) orelse return;
    const child_node = pool.get(child) orelse return;

    std.debug.print("Parenting node {*} type {any} to {*} type {any}\n", .{ child_node, child_node.data, parent_node, parent_node.data });

    // Set parent-child relationship
    child_node.parent = parent;
    parent_node.children.append(child) catch |err| {
        std.debug.print("Failed to append child: {any}\n", .{err});
    };
}
