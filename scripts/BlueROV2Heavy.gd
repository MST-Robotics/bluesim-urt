tool
extends RigidBody

const THRUST = 50

var interface = PacketPeerUDP.new()  # UDP socket for fdm in (server)
var peer = null
var start_time = OS.get_ticks_msec()

var last_velocity = Vector3(0, 0, 0)
var calculated_acceleration = Vector3(0, 0, 0)

var buoyancy = 1.6 + self.mass * 9.8  # Newtons
var _initial_position = 0
var phys_time = 0

onready var light_glows = [$light_glow, $light_glow2, $light_glow3, $light_glow4]

onready var ljoint = get_tree().get_root().find_node("ljoint", true, false)
onready var rjoint = get_tree().get_root().find_node("rjoint", true, false)
onready var wait_SITL = Globals.wait_SITL


func connect_fmd_in():
	if interface.listen(9002) != OK:
		print("Failed to connect fdm_in")


func get_servos():
	if not peer:
		interface.set_dest_address(Globals.SITL_IP, interface.get_packet_port())

	if not interface.get_available_packet_count():
		if wait_SITL:
			interface.wait()
		else:
			return

	var buffer = StreamPeerBuffer.new()
	buffer.data_array = interface.get_packet()

	var magic = buffer.get_u16()
	buffer.seek(2)
	var _framerate = buffer.get_u16()
	#print(_framerate)
	buffer.seek(4)
	var _framecount = buffer.get_u16()

	if magic != 18458:
		return
	for i in range(0, 15):
		buffer.seek(8 + i * 2)
		actuate_servo(i, (float(buffer.get_u16()) - 1000) / 1000)


func send_fdm():
	var buffer = StreamPeerBuffer.new()

	buffer.put_double((OS.get_ticks_msec() - start_time) / 1000.0)

	var _basis = transform.basis

# These are the same but mean different things, let's keep both for now
	var toNED = Basis(Vector3(-1, 0, 0), Vector3(0, 0, -1), Vector3(1, 0, 0))

	toNED = Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))

	var toFRD = Basis(Vector3(0, -1, 0), Vector3(0, 0, -1), Vector3(1, 0, 0))

	var _angular_velocity = toFRD.xform(_basis.xform_inv(angular_velocity))
	var gyro = [_angular_velocity.x, _angular_velocity.y, _angular_velocity.z]

	var _acceleration = toFRD.xform(_basis.xform_inv(calculated_acceleration))

	var accel = [_acceleration.x, _acceleration.y, _acceleration.z]

	# var orientation = toFRD.xform(Vector3(-rotation.x, - rotation.y, -rotation.z))
	var quaternon = Basis(-_basis.z, _basis.x, _basis.y).rotated(Vector3(1, 0, 0), PI).rotated(Vector3(1, 0, 0), PI / 2).get_rotation_quat()

	var euler = quaternon.get_euler()
	euler = [euler.y, euler.x, euler.z]

	var _velocity = toNED.xform(self.linear_velocity)
	var velo = [_velocity.x, _velocity.y, _velocity.z]

	var _position = toNED.xform(self.transform.origin)
	var pos = [_position.x, _position.y, _position.z]

	var IMU_fmt = {"gyro": gyro, "accel_body": accel}
	var JSON_fmt = {
		"timestamp": phys_time,
		"imu": IMU_fmt,
		"position": pos,
		"quaternion": [quaternon.w, quaternon.x, quaternon.y, quaternon.z],
		"velocity": velo
	}
	var JSON_string = "\n" + JSON.print(JSON_fmt) + "\n"
	buffer.put_utf8_string(JSON_string)
	interface.put_packet(buffer.data_array)


func get_motors_table_entry(thruster):
	var thruster_vector = (thruster.transform.basis*Vector3(1,0,0)).normalized()
	var roll = Vector3(0,0,-1).cross(thruster.translation).normalized().dot(thruster_vector)
	var pitch = Vector3(1,0,0).cross(thruster.translation).normalized().dot(thruster_vector)
	var yaw = Vector3(0,1,0).cross(thruster.translation).normalized().dot(thruster_vector)
	var forward = Vector3(0,0,-1).dot(thruster_vector)
	var lateral = Vector3(1,0,0).dot(thruster_vector)
	var vertical = Vector3(0,-1,0).dot(thruster_vector)
	if abs(roll) < 0.15 or not thruster.roll_factor:
		roll = 0
	if abs(pitch) < 0.15 or not thruster.pitch_factor:
		pitch = 0
	if abs(yaw) < 0.15 or not thruster.yaw_factor:
		yaw = 0
	if abs(vertical) < 0.15 or not thruster.vertical_factor :
		vertical = 0
	if abs(forward) < 0.15 or not thruster.forward_factor:
		forward = 0
	if abs(lateral) < 0.15 or not thruster.lateral_factor:
		lateral = 0
	return [roll, pitch, yaw, vertical, forward, lateral]

func calculate_motors_matrix():
	print("Calculated Motors Matrix:")
	var thrusters = []
	var i = 1
	for child in get_children():
		if child.get_class() ==  "Thruster":
			thrusters.append(child)
	for thruster in thrusters:
		var entry = get_motors_table_entry(thruster)
		entry.insert(0, i)
		i = i + 1
		print("add_motor_raw_6dof(AP_MOTORS_MOT_%s,\t%s,\t%s,\t%s,\t%s,\t%s,\t%s);" % entry)

func _ready():
	if Engine.is_editor_hint():
		calculate_motors_matrix()
		return
	if Globals.active_vehicle == "bluerovheavy":
		$Camera.set_current(true)
	_initial_position = get_global_transform().origin
	set_physics_process(true)
	if typeof(Globals.active_vehicle) == TYPE_STRING and Globals.active_vehicle == "bluerovheavy":
		Globals.active_vehicle = self
	else:
		return
	if not Globals.isHTML5:
		connect_fmd_in()


func _physics_process(delta):
	if Engine.is_editor_hint():
		return
	phys_time = phys_time + 1.0 / Globals.physics_rate
	process_keys()
	if Globals.isHTML5:
		return
	calculated_acceleration = (self.linear_velocity - last_velocity) / delta
	calculated_acceleration.y += 10
	last_velocity = self.linear_velocity
	get_servos()
	send_fdm()


func add_force_local(force: Vector3, pos: Vector3):
	var pos_local = self.transform.basis.xform(pos)
	var force_local = self.transform.basis.xform(force)
	self.add_force(force_local, pos_local)


func actuate_servo(id, percentage):
	if percentage == 0:
		return

	var force = (percentage - 0.5) * 2 * -THRUST
	match id:
		0:
			self.add_force_local($t1.transform.basis*Vector3(force,0,0), $t1.translation)
		1:
			self.add_force_local($t2.transform.basis*Vector3(force,0,0), $t2.translation)
		2:
			self.add_force_local($t3.transform.basis*Vector3(force,0,0), $t3.translation)
		3:
			self.add_force_local($t4.transform.basis*Vector3(force,0,0), $t4.translation)
		4:
			self.add_force_local($t5.transform.basis*Vector3(force,0,0), $t5.translation)
		5:
			self.add_force_local($t6.transform.basis*Vector3(force,0,0), $t6.translation)
		6:
			self.add_force_local($t7.transform.basis*Vector3(force,0,0), $t7.translation)
		7:
			self.add_force_local($t8.transform.basis*Vector3(force,0,0), $t8.translation)
		8:
			$Camera.rotation_degrees.x = -45 + 90 * percentage
		9:
			percentage -= 0.1
			$light1.light_energy = percentage * 5
			$light2.light_energy = percentage * 5
			$light3.light_energy = percentage * 5
			$light4.light_energy = percentage * 5
			$scatterlight.light_energy = percentage * 2.5
			if percentage < 0.01 and light_glows[0].get_parent() != null:
				for light in light_glows:
					self.remove_child(light)
			elif percentage > 0.01 and light_glows[0].get_parent() == null:
				for light in light_glows:
					self.add_child(light)

		10:
			if percentage < 0.4:
				ljoint.set_param(6, 1)
				rjoint.set_param(6, -1)
			elif percentage > 0.6:
				ljoint.set_param(6, -1)
				rjoint.set_param(6, 1)
			else:
				ljoint.set_param(6, 0)
				rjoint.set_param(6, 0)


func _unhandled_input(event):
	if event is InputEventKey:
		# There are for debugging:
		# Some forces:
		if event.pressed and event.scancode == KEY_X:
			self.add_central_force(Vector3(30, 0, 0))
		if event.pressed and event.scancode == KEY_Y:
			self.add_central_force(Vector3(0, 30, 0))
		if event.pressed and event.scancode == KEY_Z:
			self.add_central_force(Vector3(0, 0, 30))
		# Reset position
		if event.pressed and event.scancode == KEY_R:
			set_translation(_initial_position)
		# Some torques
		if event.pressed and event.scancode == KEY_Q:
			self.add_torque(self.transform.basis.xform(Vector3(15, 0, 0)))
		if event.pressed and event.scancode == KEY_T:
			self.add_torque(self.transform.basis.xform(Vector3(0, 15, 0)))
		if event.pressed and event.scancode == KEY_E:
			self.add_torque(self.transform.basis.xform(Vector3(0, 0, 15)))
		# Some hard-coded positions (used to check accelerometer)
		if event.pressed and event.scancode == KEY_U:
			self.look_at(Vector3(0, 100, 0), Vector3(0, 0, 1))  # expects +X
			mode = RigidBody.MODE_STATIC
		if event.pressed and event.scancode == KEY_I:
			self.look_at(Vector3(100, 0, 0), Vector3(0, 100, 0))  #expects +Z
			mode = RigidBody.MODE_STATIC
		if event.pressed and event.scancode == KEY_O:
			self.look_at(Vector3(100, 0, 0), Vector3(0, 0, -100))  #expects +Y
			mode = RigidBody.MODE_STATIC

		if event.pressed and event.is_action("camera_switch"):
			if $Camera.is_current():
				$Camera.clear_current(true)
			else:
				$Camera.set_current(true)

	if event.is_action("lights_up"):
		var percentage = min(max(0, $light1.light_energy + 0.1), 5)
		if percentage > 0:
			for light in light_glows:
				self.add_child(light)
		$light1.light_energy = percentage
		$light2.light_energy = percentage
		$light3.light_energy = percentage
		$light4.light_energy = percentage
		$scatterlight.light_energy = percentage * 0.5

	if event.is_action("lights_down"):
		var percentage = min(max(0, $light1.light_energy - 0.1), 5)
		$light1.light_energy = percentage
		$light2.light_energy = percentage
		$light3.light_energy = percentage
		$light4.light_energy = percentage
		$scatterlight.light_energy = percentage * 0.5
		if percentage == 0:
			for light in light_glows:
				self.remove_child(light)


func process_keys():
	if Input.is_action_pressed("forward"):
		self.add_force_local(Vector3(0, 0, 40), Vector3(0, -0.05, 0))
	elif Input.is_action_pressed("backwards"):
		self.add_force_local(Vector3(0, 0, -40), Vector3(0, -0.05, 0))

	if Input.is_action_pressed("strafe_right"):
		self.add_force_local(Vector3(-40, 0, 0), Vector3(0, -0.05, 0))
	elif Input.is_action_pressed("strafe_left"):
		self.add_force_local(Vector3(40, 0, 0), Vector3(0, -0.05, 0))

	if Input.is_action_pressed("upwards"):
		self.add_force_local(Vector3(0, 70, 0), Vector3(0, -0.05, 0))
	elif Input.is_action_pressed("downwards"):
		self.add_force_local(Vector3(0, -70, 0), Vector3(0, -0.05, 0))

	if Input.is_action_pressed("rotate_left"):
		self.add_torque(self.transform.basis.xform(Vector3(0, 20, 0)))
	elif Input.is_action_pressed("rotate_right"):
		self.add_torque(self.transform.basis.xform(Vector3(0, -20, 0)))

	if Input.is_action_pressed("camera_up"):
		$Camera.rotation_degrees.x = min($Camera.rotation_degrees.x + 0.1, 45)
	elif Input.is_action_pressed("camera_down"):
		$Camera.rotation_degrees.x = max($Camera.rotation_degrees.x - 0.1, -45)

	if Input.is_action_pressed("gripper_open"):
		ljoint.set_param(6, 1)
		rjoint.set_param(6, -1)
	elif Input.is_action_pressed("gripper_close"):
		ljoint.set_param(6, -1)
		rjoint.set_param(6, 1)
	else:
		ljoint.set_param(6, 0)
		rjoint.set_param(6, 0)
