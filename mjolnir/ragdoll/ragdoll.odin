package ragdoll

import "../animation"
import "../physics"
import "core:math"
import "core:math/linalg"

// JointKind is how a block hangs off its parent block.
JointKind :: enum {
  NONE, // free: the block only collides
  BALL, // swings freely, or within Block.cone
  HINGE, // turns about the axis normal to both blocks' limbs, within Block.lower..upper
}

// Block is one physics box of a ragdoll, spanning the bones start..end of its limb. You edit
// blocks freely; the ragdoll only reads them, and picks up edits at the next bodies_create.
Block :: struct {
  name:   string,
  start:  u32, // bone the block begins at, where its joint to the parent sits
  end:    u32, // bone the limb runs to, defining the block's direction
  parent: int, // index of the parent block, -1 for the root block (index 0)
  joint:  JointKind,
  cone:   f32, // BALL: largest swing from the rest pose, radians; 0 = free
  lower:  f32, // HINGE: turn limits from the rest pose, radians; free unless upper > lower
  upper:  f32,
  back:   f32, // how far the block reaches behind start, along the limb
  extend: f32, // how far it reaches past end
  size:   [3]f32, // half extents in model units: across, along the limb, front to back; along <= 0 spans the bones (fit_length)
}

// Ragdoll maps blocks onto the bones of one skeleton. init it, make its bodies in a physics
// World (bodies_create), step that world, then sync the bone pose from the blocks every tick.
Ragdoll :: struct {
  blocks:  []Block, // fixed in count after init
  scale:   f32, // model to world scale, applied at bodies_create and sync
  density: f32, // kg per cubic world unit, sets the mass of each block at bodies_create
  using _: Ragdoll_State,
}

@(private)
Ragdoll_State :: struct {
  owner:    []int, // per bone, the block that carries it
  rest_skin: []matrix[4, 4]f32, // per bone, its rest pose times its inverse bind
  span:     []f32, // per block, rest distance from its start bone to its end bone
  dir:      [][3]f32, // per block, rest limb direction in model space
  pivot:    [][3]f32, // per block, rest position of its start bone
  rot:      []quaternion128, // per block, rest orientation: local Y along the limb
  bodies:   []physics.BodyHandle, // none until bodies_create
  masses:   []f32,
  joints:   [dynamic]physics.JointHandle,
}

// init maps blocks onto skeleton; blocks must outlive the ragdoll and not change in count. A
// bone follows the block of its nearest ancestor (or itself) that starts a block; bones above
// every block follow block 0. Fails on bad bone indices or a block whose two bones coincide.
init :: proc(self: ^Ragdoll, skeleton: ^animation.Skeleton, blocks: []Block) -> bool {
  n := len(blocks)
  bones := len(skeleton.bind)
  if n == 0 do return false
  for b in blocks do if int(b.start) >= bones || int(b.end) >= bones || b.parent >= n do return false
  self^ = {
    blocks   = blocks,
    scale    = 1,
    density  = 600,
  }
  self.owner = make([]int, bones)
  self.rest_skin = make([]matrix[4, 4]f32, bones)
  for &m, bone in self.rest_skin do m = skeleton.bind[bone] * skeleton.inverse_bind[bone]
  self.span = make([]f32, n)
  self.dir = make([][3]f32, n)
  self.pivot = make([][3]f32, n)
  self.rot = make([]quaternion128, n)
  self.bodies = make([]physics.BodyHandle, n)
  self.masses = make([]f32, n)
  for b, i in blocks {
    from := skeleton.bind[b.start][3].xyz
    d := skeleton.bind[b.end][3].xyz - from
    length := linalg.length(d)
    if length < 1e-6 {
      destroy(self)
      return false
    }
    self.span[i] = length
    self.dir[i] = d / length
    self.pivot[i] = from
    self.rot[i] = limb_rotation(self.dir[i])
  }
  for bone in 0 ..< bones {
    cursor := i32(bone)
    for cursor >= 0 {
      found := -1
      for b, i in blocks do if int(b.start) == int(cursor) do found = i
      if found >= 0 {
        self.owner[bone] = found
        break
      }
      cursor = skeleton.parents[cursor]
    }
  }
  return true
}

// destroy frees the ragdoll's memory. Destroy its bodies (bodies_destroy) first.
destroy :: proc(self: ^Ragdoll) {
  delete(self.owner)
  delete(self.rest_skin)
  delete(self.span)
  delete(self.dir)
  delete(self.pivot)
  delete(self.rot)
  delete(self.bodies)
  delete(self.masses)
  delete(self.joints)
  self^ = {}
}

@(private)
limb_rotation :: proc(dir: [3]f32) -> quaternion128 {
  up := [3]f32{0, 0, 1}
  if abs(dir.z) > 0.9 do up = {1, 0, 0}
  x := linalg.normalize(linalg.cross(dir, up))
  z := linalg.cross(x, dir)
  return linalg.quaternion_from_matrix3(matrix[3, 3]f32{
    x.x, dir.x, z.x,
    x.y, dir.y, z.y,
    x.z, dir.z, z.z,
  })
}

// fit_length is the half length along the limb that makes block i span its bones, including
// back and extend. Use it to start editing Block.size from the skeleton.
fit_length :: proc(self: ^Ragdoll, i: int) -> f32 {
  b := self.blocks[i]
  return 0.5 * (self.span[i] + b.back + b.extend)
}

@(private)
half_size :: proc(self: ^Ragdoll, i: int) -> [3]f32 {
  size := self.blocks[i].size
  if size.y <= 0 do size.y = fit_length(self, i)
  return size
}

// The block's center in model space at rest.
@(private)
rest_center :: proc(self: ^Ragdoll, i: int) -> [3]f32 {
  return self.pivot[i] + self.dir[i] * (half_size(self, i).y - self.blocks[i].back)
}

// ground_height is how high above the ground to put the model's origin so that the lowest
// block rests on it, at the current scale and sizes.
ground_height :: proc(self: ^Ragdoll) -> f32 {
  low := f32(math.F32_MAX)
  for i in 0 ..< len(self.blocks) {
    m := linalg.matrix3_from_quaternion(self.rot[i])
    h := half_size(self, i)
    reach := abs(m[1, 0]) * h.x + abs(m[1, 1]) * h.y + abs(m[1, 2]) * h.z
    low = min(low, rest_center(self, i).y - reach)
  }
  return -low * self.scale
}

// bodies_create creates the blocks as bodies of world, in the skeleton's rest pose with the model
// origin at `origin`, replacing any earlier ones. simulate = false makes them static, for
// picking and editing; true makes them dynamic and joins them with their joints.
// Body user links are left to you. Edits to blocks, scale and density take effect here.
bodies_create :: proc(self: ^Ragdoll, world: ^physics.World, origin: [3]f32, simulate := true) {
  bodies_destroy(self, world)
  s := self.scale
  for _, i in self.blocks {
    half := half_size(self, i) * s
    mass := f32(0)
    if simulate do mass = max(0.3, self.density * 8 * half.x * half.y * half.z)
    self.masses[i] = mass
    self.bodies[i] = physics.body_create(world, origin + rest_center(self, i) * s, self.rot[i], physics.BoxCollider{half_extents = half}, mass)
    if simulate {
      params := physics.body_params(world, self.bodies[i])
      params.linear_damping = 0.05
      params.angular_damping = 0.4
    }
  }
  if !simulate do return
  for b, i in self.blocks do if b.parent >= 0 {
    anchor := origin + self.pivot[i] * s
    joint: physics.Joint
    switch b.joint {
    case .NONE:
      continue
    case .BALL:
      joint = physics.BallJoint{anchor = anchor, axis = self.dir[i], cone = b.cone}
    case .HINGE:
      axis := linalg.cross(self.dir[b.parent], self.dir[i])
      axis = linalg.length(axis) > 1e-3 ? linalg.normalize(axis) : [3]f32{1, 0, 0}
      joint = physics.HingeJoint{anchor = anchor, axis = axis, lower = b.lower, upper = b.upper}
    }
    if handle, ok := physics.joint_create(world, self.bodies[i], self.bodies[b.parent], joint); ok {
      append(&self.joints, handle)
    }
  }
}

// bodies_destroy destroys the ragdoll's bodies and joints in world. A ragdoll without bodies is
// left alone.
bodies_destroy :: proc(self: ^Ragdoll, world: ^physics.World) {
  if !has_bodies(self) do return
  for j in self.joints do physics.joint_destroy(world, j)
  clear(&self.joints)
  for &h in self.bodies {
    physics.body_destroy(world, h)
    h = {}
  }
}

@(private)
has_bodies :: proc(self: ^Ragdoll) -> bool {
  return len(self.bodies) > 0 && self.bodies[0] != {}
}

// body returns the physics body of block i, none before bodies_create.
body :: proc(self: ^Ragdoll, i: int) -> physics.BodyHandle {
  return self.bodies[i]
}

// mass returns the mass block i got at bodies_create: 0 for static bodies.
mass :: proc(self: ^Ragdoll, i: int) -> f32 {
  return self.masses[i]
}

// block_of returns the block a physics body belongs to, for picking with physics.raycast.
block_of :: proc(self: ^Ragdoll, handle: physics.BodyHandle) -> (block: int, ok: bool) #optional_ok {
  if !has_bodies(self) do return
  for h, i in self.bodies do if h == handle do return i, true
  return
}

// block_pose returns where block i is in world, and its half extents there: all you need to draw it.
block_pose :: proc(
  self: ^Ragdoll,
  world: ^physics.World,
  i: int,
) -> (
  position: [3]f32,
  rotation: quaternion128,
  half_extents: [3]f32,
  ok: bool,
) {
  if !has_bodies(self) do return
  b := physics.body(world, self.bodies[i]) or_return
  return b.position, b.rotation, half_size(self, i) * self.scale, true
}

// sync writes the skinning palette (one matrix per bone) that poses the mesh like the blocks,
// for a model drawn at the returned origin with uniform `scale` and no rotation: place the
// model's node there and stage the palette (render.stage_bones). The origin follows block 0,
// so the mesh bounds stay near the ragdoll. Fails, leaving palette alone, before bodies_create or
// when the palette is shorter than the skeleton.
sync :: proc(self: ^Ragdoll, world: ^physics.World, palette: []matrix[4, 4]f32) -> (origin: [3]f32, ok: bool) {
  if !has_bodies(self) || len(palette) < len(self.owner) do return
  root := physics.body(world, self.bodies[0]) or_return
  s := [3]f32{self.scale, self.scale, self.scale}
  scale := linalg.matrix4_scale(s)
  origin = root.position - rest_center(self, 0) * self.scale
  to_model := linalg.matrix4_inverse(linalg.matrix4_translate(origin) * scale)
  carry := make([]matrix[4, 4]f32, len(self.blocks), context.temp_allocator)
  for i in 0 ..< len(self.blocks) {
    carry[i] = linalg.MATRIX4F32_IDENTITY
    b := physics.body(world, self.bodies[i]) or_continue
    now := to_model * linalg.matrix4_from_trs(b.position, b.rotation, [3]f32{1, 1, 1}) * scale
    rest := linalg.matrix4_from_trs(rest_center(self, i), self.rot[i], [3]f32{1, 1, 1})
    carry[i] = now * linalg.matrix4_inverse(rest)
  }
  for bone in 0 ..< len(self.owner) {
    palette[bone] = carry[self.owner[bone]] * self.rest_skin[bone]
  }
  return origin, true
}
