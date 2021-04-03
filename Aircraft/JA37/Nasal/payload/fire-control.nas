#### Weapons firing logic.

var TRUE = 1;
var FALSE = 0;


var find_index = func(val, vec) {
    forindex(var i; vec) if (vec[i] == val) return i;
    return nil;
}


var input = {
    trigger:    "/controls/armament/trigger",
    unsafe:     "/controls/armament/trigger-unsafe",
    trigger_m70:    "/controls/armament/trigger-m70",
    release:    "/instrumentation/indicators/release-complete",
    release_fail:   "/instrumentation/indicators/release-failed",
    mp_msg:     "/payload/armament/msg",
    atc_msg:    "/sim/messages/atc",
    rb05_pitch: "/payload/armament/rb05-control-pitch",
    rb05_yaw:   "/payload/armament/rb05-control-yaw",
    speed_kt:   "/velocities/groundspeed-kt",
    gear_pos:   "/gear/gear/position-norm",
    time:       "/sim/time/elapsed-sec",
    start_left: "/controls/armament/ground-panel/start-left",
};

foreach (var prop; keys(input)) {
    input[prop] = props.globals.getNode(input[prop], 1);
}


var fireLog = events.LogBuffer.new(echo: 0);


### Pylon names
var STATIONS = pylons.STATIONS;


### Weapon logic API (abstract class)
#
# Different weapon types should inherit this object and define the methods,
# so as to implement custom firing logic.
var WeaponLogic = {
    new: func(type) {
        var m = { parents: [WeaponLogic] };
        m.type = type;
        m.unsafe = FALSE;
        return m;
    },

    # Select a weapon.
    # Either a specific pylon (if the argument is specified),
    # or this type of weapon in general.
    # Must return TRUE on successful selection, and FALSE if it failed.
    # In the later case, the state of the weapon should be the same as after deselect().
    select: func(pylon=nil) {
        die("Called unimplemented abstract class method");
    },

    # Select the next weapon of this type (when it makes sense).
    cycle_selection: func {
        die("Called unimplemented abstract class method");
    },

    # Deselect this weapon type.
    deselect: func {
        die("Called unimplemented abstract class method");
    },

    # Called when the trigger safety changes position while this weapon type is selected.
    set_unsafe: func(unsafe) {
        if (!firing_enabled()) unsafe = FALSE;
        me.unsafe = unsafe;
        if (!me.unsafe) me.set_trigger(FALSE);
    },

    armed: func {
        return me.unsafe;
    },

    # Called when the trigger is pressed/released while this weapon type is selected.
    set_trigger: func(trigger) {
        die("Called unimplemented abstract class method");
    },

    # Used by the HUD. Only bombs, guns, and rockets use it.
    is_firing: func { return FALSE; },

    weapon_ready: func { return FALSE; },

    # Return ammo count for this type of weapon.
    get_ammo: func { return pylons.get_ammo(me.type); },

    # Return the active weapon object (created from missile.nas), when it makes sense.
    get_weapon: func { return nil; },

    # Return an array containing selected stations.
    get_selected_pylons: func { return []; },
};


### Generic missile weapons, based on missiles.nas
var Missile = {
    parents: [WeaponLogic],

    # Selection order.
    pylons_priority_left: [STATIONS.R7V, STATIONS.R7H, STATIONS.V7V, STATIONS.V7H, STATIONS.S7V, STATIONS.S7H],
    pylons_priority_right: [STATIONS.R7H, STATIONS.R7V, STATIONS.V7H, STATIONS.V7V, STATIONS.S7H, STATIONS.S7V],

    pylons_priority: func {
        if (me.can_start_right and !input.start_left.getBoolValue()) {
            return me.pylons_priority_right;
        } else {
            return me.pylons_priority_left;
        }
    },

    # Additional parameters:
    #   falld_last: (bool) If the FALLD LAST indicator (for AJS) should light up after release.
    #   fire_delay: (float) Delay between trigger pull and firing.
    #   at_everything: (bool) Required for any lock after launch, change of lock, multiple target hit...
    #   no_lock: (bool) Allow firing without missile lock.
    #   cycling: (bool) Cycling pylon is allowed with the FRAMSTEGN button. default ON
    #   can_start_right: (bool) The AJS ground panel L/R switch is taken in account to choose the first fired side.
    new: func(type, falld_last=0, fire_delay=0, at_everything=0, no_lock=0, cycling=1, can_start_right=0) {
        var w = { parents: [Missile, WeaponLogic.new(type)], };
        w.selected = nil;
        w.station = nil;
        w.weapon = nil;
        w.fired = FALSE;
        w.falld_last = falld_last;
        w.fire_delay = fire_delay;
        w.at_everything = at_everything;
        w.no_lock = no_lock;
        w.cycling = cycling;
        w.can_start_right = can_start_right;

        if (w.fire_delay > 0) {
            w.release_timer = maketimer(w.fire_delay, w, w.release_weapon);
            w.release_timer.simulatedTime = TRUE;
            w.release_timer.singleShot = TRUE;
        }

        w.seeker_timer = maketimer(0.5, w, w.seeker_loop);

        w.is_IR = (type == "RB-24" or type == "RB-24J" or type == "RB-74");
        w.is_rb75 = type == "RB-75";
        if (w.is_IR and variant.JA) w.last_IR_lock = nil;
        if (w.is_rb75) {
            w.rb75_timer = maketimer(0.05, w, w.rb75_loop);
            w.last_click = FALSE;
            w.rb75_lock = FALSE;
            # Seeker position in degrees
            w.rb75_pos_x = 0;
            w.rb75_pos_y = -1.3;
        }

        return w;
    },

    # Internal function. pylon must be correct (loaded with correct type...)
    _select: func(pylon) {
        # First reset state
        me.deselect();

        me.selected = pylon;
        me.station = pylons.station_by_id(me.selected);
        me.weapon = me.station.getWeapons()[0];
        me.fired = FALSE;
        setprop("controls/armament/station-select-custom", pylon);
    },

    deselect: func {
        me.set_unsafe(FALSE);
        me.selected = nil;
        me.station = nil;
        me.weapon = nil;
        me.fired = FALSE;
        setprop("controls/armament/station-select-custom", -1);
    },

    select: func(pylon=nil) {
        if (pylon == nil) {
            # Pylon not given as argument. Find a matching one.
            pylon = pylons.find_pylon_by_type(me.type, me.pylons_priority());
        } else {
            # Pylon given as argument. Check that it matches.
            if (!pylons.is_loaded_with(pylon, me.type)) pylon = nil;
        }

        # If pylon is nil at this point, selection failed.
        if (pylon == nil) {
            me.deselect();
            return FALSE;
        } else {
            me._select(pylon);
            return TRUE;
        }
    },

    # Internal function, select next missile of same type.
    _cycle_selection: func {
        # Cycling is only possible when trigger is safed.
        if (me.unsafe) return !me.fired;

        var priority = me.pylons_priority();

        var first = 0;
        if (me.selected != nil) {
            first = find_index(me.selected, priority)+1;
            if (first >= size(priority)) first = 0;
        }

        pylon = pylons.find_pylon_by_type(me.type, priority, first);
        if (pylon == nil) {
            me.deselect();
            return FALSE;
        } else {
            me._select(pylon);
            return TRUE;
        }
    },

    # Called when pressing the 'cycle missile' button.
    # Same as _cycle_selection, unless cycling is disabled by the argument cycling in the constructor.
    cycle_selection: func {
        if (me.cycling) me._cycle_selection();
    },

    set_unsafe: func(unsafe) {
        # Call parent method
        call(WeaponLogic.set_unsafe, [unsafe], me);

        if (me.weapon != nil) {
            if (me.unsafe) {
                # Setup weapon
                me.weapon.start();
                me.seeker_timer.start();

                # IR weapons parameters.
                if (me.is_IR or me.is_rb75) {
                    if (!variant.JA) {
                        # For AJS, locked on bore.
                        me.weapon.setAutoUncage(FALSE);
                        me.weapon.setCaged(TRUE);
                        me.weapon.setSlave(TRUE);
                        # Boresight position
                        if (me.is_rb75) {
                            me.rb75_lock = FALSE;
                            me.rb75_pos_x = 0;
                            me.rb75_pos_y = -1.3; # 1.3deg down initially (manual).
                            me.weapon.commandDir(me.rb75_pos_x, me.rb75_pos_y);
                        } else {
                            # 0.8 deg down, except for outer pylons (AJS SFI part 3);
                            if (me.selected == STATIONS.R7V or me.selected == STATIONS.R7H) {
                                me.weapon.commandDir(0,0);
                            } else {
                                me.weapon.commandDir(0,-0.8);
                            }
                        }
                    } else {
                        me.weapon.setUncagedPattern(3, 2.5, -12);
                    }
                }
                # Loop for Rb 75 seeker slewing.
                if (me.is_rb75) {
                    displays.common.resetCursorDelta();
                    me.rb75_timer.start();
                }
            } else {
                if (me.is_rb75) me.rb75_timer.stop();
                me.seeker_timer.stop();
                me.weapon.stop();
            }
        }

        # Select next weapon when safing after firing.
        if (me.fired and !me.unsafe) {
            me.fired = FALSE;
            me._cycle_selection();
        }

        # FALLD LAST off when safing.
        if (!me.unsafe) input.release.setBoolValue(FALSE);

        # Interupt firing sequence if timer is running.
        if (!me.unsafe and me.fire_delay > 0 and me.release_timer.isRunning) {
            me.release_timer.stop();
            input.release_fail.setBoolValue(TRUE);
        }
    },

    release_weapon: func {
        var phrase = me.weapon.brevity;
        if (me.weapon.status == armament.MISSILE_LOCK) {
            phrase = phrase~" at: "~me.weapon.callsign;
        }
        fireLog.push("Self: "~phrase);

        me.station.fireWeapon(0, me.at_everything ? radar_logic.complete_list : nil);

        me.weapon = nil;
        me.fired = TRUE;
        input.release.setBoolValue(me.falld_last);
    },

    set_trigger: func(trigger) {
        if (!me.armed() or !trigger or me.weapon == nil
            or (!me.no_lock and me.weapon.status != armament.MISSILE_LOCK)
            or (me.is_rb75 and !me.rb75_can_fire())) return;

        if (me.fire_delay > 0) me.release_timer.start();
        else me.release_weapon();
    },

    # Allows the seeker to follow a target it is locked on.
    _uncage_seeker: func {
        # With these specific parameters, the seeker is free to follow the target,
        # but will become non-functioning and require reset if it looses lock.
        # (alternative is it coming back to boresight or uncaged pattern after loosing lock...)
        me.weapon.setAutoUncage(TRUE);
        me.weapon.setSlave(FALSE);
    },

    # Reset seeker after calling _uncage_seeker()
    _reset_seeker: func {
        me.weapon.setAutoUncage(FALSE);
        me.weapon.setCaged(TRUE);
        me.weapon.setSlave(TRUE);
    },

    # IR seeker manipulation
    uncage_IR_seeker: func {
        if (variant.JA or me.weapon == nil or me.weapon.status != armament.MISSILE_LOCK
            or (me.weapon.type != "RB-24J" and me.weapon.type != "RB-74")) return;
        me._uncage_seeker();
    },

    reset_IR_seeker: func {
        if (variant.JA or me.weapon == nil
            or (me.weapon.type != "RB-24J" and me.weapon.type != "RB-74")) return;
        me._reset_seeker();
        me.weapon.commandDir(0,0);
    },

    seeker_loop: func {
        if (!me.weapon_ready()) {
            me.seeker_timer.stop();
            return;
        }

        # For JA IR, switch between bore sight and radar command automatically.
        # Note: not using 'setBore()' for bore sight. Instead keeping 'setSlave()'
        # and using 'commandDir()' to allow to adjust bore position, if we want to.
        if (me.is_IR and variant.JA and me.weapon.isCaged()) {
            if (radar_logic.selection == nil or TI.ti.rb74_force_bore) {
                # 0.8 deg down is from AJS
                if (me.weapon.command_tgt) me.weapon.commandDir(0,-0.8);
            } else {
                if (!me.weapon.command_tgt) me.weapon.commandRadar();
            }
        }

        # Update list of contacts on which to lock on.
        # For IR/Rb 75, don't do anything if the missile has already locked. It would mess with the lock.
        if ((!me.is_IR and !me.is_rb75) or me.weapon.status != armament.MISSILE_LOCK) {
            # IR missiles and Rb 75 can lock without radar command.
            if ((me.is_IR or me.is_rb75) and (!me.weapon.isCaged() or !me.weapon.command_tgt)) {
                # Send list of all contacts to allow searching.
                me.weapon.setContacts(radar_logic.complete_list);
                armament.contact = nil;
            } else {
                # Slave onto radar target.
                me.weapon.setContacts([]);
                armament.contact = radar_logic.selection;
            }
        }

        # Log lock event
        if (me.is_IR and variant.JA) {
            if (me.weapon.status == armament.MISSILE_LOCK) {
                if (me.last_IR_lock != me.weapon.callsign) {
                    radar_logic.lockLog.push(sprintf("IR lock on to %s (%s)", me.weapon.callsign, me.weapon.type));
                    me.last_IR_lock = me.weapon.callsign;
                }
            } else {
                me.last_IR_lock = nil;
            }
        }
    },

    rb75_loop: func {
        if (!me.weapon_ready()) {
            me.rb75_timer.stop();
            return;
        }

        var cursor = displays.common.getCursorDelta();
        displays.common.resetCursorDelta();

        if (cursor[2] and !me.last_click) {
            # Clicked
            if (me.rb75_lock) {
                # Unlock and reset position
                me.rb75_lock = FALSE;
                me.rb75_pos_x = 0;
                me.rb75_pos_y = -1.3; # 1.3deg down initially (manual).
                me._reset_seeker();
                me.weapon.commandDir(me.rb75_pos_x, me.rb75_pos_y);
            } elsif (me.weapon.status == armament.MISSILE_LOCK) {
                # Lock
                me.rb75_lock = TRUE;
                me._uncage_seeker();
            }
        }
        if (!me.rb75_lock) {
            # Slew cursor
            me.rb75_pos_x = math.clamp(me.rb75_pos_x + cursor[0]*5, -15, 15);
            me.rb75_pos_y = math.clamp(me.rb75_pos_y - cursor[1]*5, -15, 15);
            me.weapon.commandDir(me.rb75_pos_x, me.rb75_pos_y);
        }
        me.last_click = cursor[2];
    },

    rb75_can_fire: func {
        if (!me.rb75_lock) return FALSE;
        var seeker_pos = me.weapon.getSeekerInfo();
        return seeker_pos != nil
            and seeker_pos[0] >= -15 and seeker_pos[0] <= 15
            and seeker_pos[1] >= -15 and seeker_pos[1] <= 15;
    },

    get_weapon: func { return me.weapon; },

    weapon_ready: func { return me.weapon != nil; },

    get_selected_pylons: func {
        if (me.selected == nil) return [];
        else return [me.selected];
    },
};

### Rb-05 has some special additional logic for remote control.
var Rb05 = {
    parents: [Missile.new(type:"RB-05A", cycling:0, can_start_right:1)],

    active_rb05: nil,

    makeMidFlightFunction: func(pylon) {
        return func(state) {
            # Missile can be controlled ~1.7s after launch (manual)
            if (state.time_s < 1.7 or Rb05.active_rb05 != pylon) return {};
            else return {
                remote_yaw: input.rb05_yaw.getValue(),
                remote_pitch: input.rb05_pitch.getValue(),
            };
        };
    },

    set_trigger: func(trigger) {
        if (!me.armed() or !trigger or me.weapon == nil) return;

        me.active_rb05 = me.selected;
        me.weapon.mfFunction = me.makeMidFlightFunction(me.selected);

        fireLog.push("Self: "~me.weapon.brevity);

        me.station.fireWeapon(0, radar_logic.complete_list);

        me.weapon = nil;
        me.fired = TRUE;
    },
};


### Generic submodel based weapon (gun, rockets).
# Expect the underlying weapon to be an instance of stations.SubModelWeapon.
var SubModelWeapon = {
    parents: [WeaponLogic],

    new: func(type, ammo_factor=1) {
        var w = { parents: [SubModelWeapon, WeaponLogic.new(type)], };
        w.selected = [];
        w.stations = [];
        w.weapons = [];

        w.firing = FALSE;

        # Ammunition count is very important and a bit tricky, because it is used in 'weapon_ready()'.
        # Cache the results for efficiency.
        w.ammo = 0;
        w.ammo_factor = ammo_factor;
        w.ammo_update_timer = maketimer(0.05, w, w._update_ammo);
        w.simulatedTime = 1;
        return w;
    },

    # Argument ignored. Always select all weapons of this type.
    select: func (pylon=nil) {
        me.deselect();

        me.selected = pylons.find_all_pylons_by_type(me.type);
        if (size(me.selected) == 0) {
            me.selected = [];
            return FALSE;
        }

        setsize(me.stations, size(me.selected));
        setsize(me.weapons, size(me.selected));
        forindex(var i; me.selected) {
            me.stations[i] = pylons.station_by_id(me.selected[i]);
            me.weapons[i] = me.stations[i].getWeapons()[0];
        }
        me._update_ammo();
        if (!me.weapon_ready()) {
            # no ammo
            me.selected = [];
            me.stations = [];
            me.weapons = [];
            return FALSE;
        }

        setprop("controls/armament/station-select-custom", size(me.selected) > 0 ? me.selected[0] : -1);
        return TRUE;
    },

    deselect: func (pylon=nil) {
        me.set_unsafe(FALSE);
        me.selected = [];
        me.stations = [];
        me.weapons = [];
        setprop("controls/armament/station-select-custom", -1);
    },

    cycle_selection: func {},

    set_unsafe: func(unsafe) {
        # Call parent method
        call(WeaponLogic.set_unsafe, [unsafe], me);

        var trigger_prop = input.trigger;

        if (me.type == "M70") {
            # For rockets, trigger logic is a bit different because all rockets must be fired.
            trigger_prop = input.trigger_m70;
            input.trigger_m70.setBoolValue(FALSE);
        }

        foreach(var weapon; me.weapons) {
            if (me.unsafe) weapon.start(trigger_prop);
            else weapon.stop();
        }

        if (me.unsafe) me.ammo_update_timer.start();
        else me.ammo_update_timer.stop();

        if (!me.unsafe) me.firing = FALSE;
    },

    set_trigger: func(trigger) {
        if (!me.armed() or !me.weapon_ready()) return;

        if (me.type == "M70") {
            # For rockets, set the trigger ON as required, but do not set it OFF, so that all rockets get fired.
            if (trigger) {
                input.trigger_m70.setBoolValue(TRUE);
                me.firing = TRUE;
            }
        } else {
            # For other weapons, there is nothing to do. Just remember that we are firing.
            me.firing = trigger;
        }
    },

    _update_ammo: func {
        me.ammo = call(WeaponLogic.get_ammo, [], me);
        # Update the 'firing' status if ammo is depleted.
        if (!me.weapon_ready()) me.firing = FALSE;
    },

    get_ammo: func {
        return math.ceil(me.ammo/me.ammo_factor);
    },

    weapon_ready: func {
        return me.ammo > 0;
    },

    get_selected_pylons: func {
        return me.selected;
    },

    is_firing: func {
        return me.firing;
    },
};

### M71 Bomb logic.
#
# In this class, a position is a pair [pylon, bomb] where
# pylon is the number of the station, bomb is the number of the bomb of that station.
var Bomb = {
    parents: [WeaponLogic],

    new: func(type) {
        var w = { parents: [Bomb, WeaponLogic.new(type)], };
        w.positions = [];
        w.next_pos = 0;
        w.next_weapon = nil;

        w.release_distance = 20;   # meter

        w.release_order = [];      # list of positions indicating release priority order.
        # Release order: fuselage R/L alternating, then wing R/L alternating (AJS manual)
        for(var i=0; i<4; i+=1) {
            append(w.release_order, [STATIONS.S7H, i]);
            append(w.release_order, [STATIONS.S7V, i]);
        }
        for(var i=0; i<4; i+=1) {
            append(w.release_order, [STATIONS.V7H, i]);
            append(w.release_order, [STATIONS.V7V, i]);
        }

        w.drop_bomb_timer = maketimer(0, w, w.drop_next_bomb);
        w.drop_bomb_timer.simulatedTime = TRUE;
        w.drop_bomb_timer.singleShot = FALSE;

        w.firing = FALSE;

        return w;
    },

    select: func(pylon=nil) {
        me.deselect();

        foreach(var pos; me.release_order) {
            if (me.is_pos_loaded(pos)) append(me.positions, pos);
        }
        if (size(me.positions) == 0) {
            return FALSE;
        } else {
            me.next_pos = 0;
            me.next_weapon = me.get_bomb_pos(me.positions[0]);
            return TRUE;
        }
    },

    deselect: func {
        me.set_unsafe(FALSE);
        me.positions = [];
        me.next_pos = 0;
        me.next_weapon = nil;
    },

    cycle_selection: func {},

    is_pos_loaded: func (pos) {
        return pylons.is_loaded_with(pos[0], me.type)
            and pylons.station_by_id(pos[0]).getWeapons()[pos[1]] != nil;
    },

    drop_bomb_pos: func (pos) {
        pylons.station_by_id(pos[0]).fireWeapon(pos[1], radar_logic.complete_list);
    },

    get_bomb_pos: func (pos) {
        return pylons.station_by_id(pos[0]).getWeapons()[pos[1]];
    },

    drop_next_bomb: func {
        if (!me.weapon_ready()) {
            me.stop_drop_sequence();
            return;
        }

        me.drop_bomb_pos(me.positions[me.next_pos]);

        me.next_pos += 1;
        if (me.next_pos < size(me.positions)) {
            me.next_weapon = me.get_bomb_pos(me.positions[me.next_pos]);
        } else {
            me.next_weapon = nil;
            input.release.setBoolValue(TRUE);
        }
    },

    release_interval: func(distance) {
        return distance / (input.speed_kt.getValue() * KT2MPS);
    },

    start_drop_sequence: func {
        me.firing = TRUE;
        me.drop_next_bomb();
        me.drop_bomb_timer.restart(me.release_interval(me.release_distance));
    },

    stop_drop_sequence: func {
        me.firing = FALSE;
        me.drop_bomb_timer.stop();
    },

    set_unsafe: func(unsafe) {
        # Call parent method
        call(WeaponLogic.set_unsafe, [unsafe], me);

        if (!me.unsafe) {
            # 'FALLD LAST' off when securing the trigger.
            input.release.setBoolValue(FALSE);
            me.firing = FALSE;
        }
    },

    set_trigger: func(trigger) {
        if (!me.armed() or !me.weapon_ready()) trigger = FALSE;

        if (trigger) {
            fireLog.push("Self: "~me.next_weapon.brevity);
            me.start_drop_sequence();
        } else {
            me.stop_drop_sequence();
        }
    },

    weapon_ready: func {
        return me.next_weapon != nil;
    },

    is_firing: func {
        return me.firing;
    },

    # Return the active weapon (object from missile.nas), when it makes sense.
    get_weapon: func {
        return me.next_weapon;
    },

    get_selected_pylons: func {
        return [];
    },
};



### List of weapon types.
if (variant.JA) {
    var weapons = [
        SubModelWeapon.new(type:"M75", ammo_factor:22), # get_ammo gives firing time
        Missile.new(type:"RB-74", fire_delay:0.7),
        Missile.new(type:"RB-99", fire_delay:0.7),
        Missile.new(type:"RB-71", fire_delay:0.7),
        Missile.new(type:"RB-24J", fire_delay:0.7),
        SubModelWeapon.new(type:"M70", ammo_factor:6),  # get_ammo gives number of pods
    ];

    # Set of indices considered for quick_select_missile() (A/A missiles)
    var quick_select = {1:1, 2:1, 3:1, 4:1,};

    var internal_gun = weapons[0];
} else {
    var weapons = [
        Missile.new(type:"RB-74", fire_delay:0.7),
        Missile.new(type:"RB-24J", fire_delay:0.7),
        Missile.new(type:"RB-24", fire_delay:0.7),
        SubModelWeapon.new("M55"),
        SubModelWeapon.new(type:"M70"),
        Missile.new(type:"RB-04E", falld_last:1, fire_delay:1, at_everything:1, no_lock:1, cycling:0),
        Missile.new(type:"RB-15F", falld_last:1, at_everything:1, no_lock:1, can_start_right:1),
        Missile.new(type:"RB-75", fire_delay:1, can_start_right:1),
        Rb05,
        Missile.new(type:"M90", at_everything:1, no_lock:1, can_start_right:1),
        Bomb.new("M71"),
        Bomb.new("M71R"),
    ];

    # Set of indices considered for quick_select_missile() (IR missiles)
    var quick_select = {0:1, 1:1, 2:1,};
}

# Selected weapon type.
var selected_index = -1;
var selected = nil;

# Internal selection function.
var _set_selected_index = func(index) {
    selected_index = index;
    if (index >= 0) selected = weapons[index];
    else selected = nil;
}


### Access functions.
var get_type = func {
    if (selected == nil) return nil;
    else return selected.type;
}

var get_weapon = func {
    if (selected == nil) return nil;
    else return selected.get_weapon();
}

var get_current_ammo = func {
    if (selected == nil) return -1;
    else return selected.get_ammo();
}

var get_selected_pylons = func {
    if (selected == nil) return [];
    else return selected.get_selected_pylons();
}

var weapon_ready = func {
    if (selected == nil) return FALSE;
    else return selected.weapon_ready();
}

var is_armed = func {
    if (selected == nil) return FALSE;
    else return selected.armed();
}

var is_firing = func {
    if (selected == nil) return FALSE;
    else return selected.is_firing();
}

### Controls

## Weapon selection.
var _deselect_current = func {
    if (selected != nil) selected.deselect();
}

# Select next weapon type in the list.
#
# If the argument 'subset' is given, only weapons whose index is in 'subset' are considered.
var cycle_weapon_type = func(subset=nil) {
    _deselect_current();

    # Cycle through weapons, starting from the previous one.
    var prev = selected_index;
    if (prev < 0) prev = size(weapons)-1;
    var i = prev;
    i += 1;
    if (i >= size(weapons)) i = 0;

    while (i != prev) {
        if ((subset == nil or contains(subset, i)) and weapons[i].select()) {
            _set_selected_index(i);
            if (!variant.JA) ja37.notice("Selected "~selected.type);
            return
        }
        i += 1;
        if (i >= size(weapons)) i = 0;
    }
    # We are back to the first weapon. Last try
    if ((subset == nil or contains(subset, i)) and weapons[i].select()) {
        _set_selected_index(i);
        if (!variant.JA) ja37.notice("Selected "~selected.type);
    } else {
        # Nothing found
        _set_selected_index(-1);
        if (!variant.JA) ja37.notice("No weapon selected");
    }
}

# For JA TI
var select_cannon = func {
    _deselect_current();
    if(internal_gun.select()) {
        _set_selected_index(0);
    } else {
        _set_selected_index(-1);
    }
}

# Throttle quick select buttons. Automatically engage aiming mode for JA.
var quick_select_cannon = func {
    # Switch to A/A aiming mode
    modes.set_aiming_mode(TRUE);
    TI.ti.ModeAttack = FALSE;
    select_cannon();
}

var quick_select_missile = func {
    if (variant.JA) {
        # Switch to A/A aiming mode
        modes.set_aiming_mode(TRUE);
        TI.ti.ModeAttack = FALSE;
    }
    cycle_weapon_type(quick_select);
}

# Next pylon of same type (left wall button)
var cycle_pylon = func {
    if (selected != nil) selected.cycle_selection();
}

var deselect_weapon = func {
    _deselect_current();
    _set_selected_index(-1);
    if (!variant.JA) ja37.notice("No weapon selected");
}

# Direct pylon selection through JA TI.
var select_pylon = func(pylon) {
    _deselect_current();

    var type = pylons.get_pylon_load(pylon);
    forindex(var i; weapons) {
        # Find matching weapon type.
        if (weapons[i].type == type) {
            # Attempt to load this pylon.
            if (weapons[i].select(pylon)) {
                _set_selected_index(i);
            } else {
                _set_selected_index(-1);
            }
            return;
        }
    }
}


## Other controls.

# IR seeker release button
var uncageIR = func {
    if (selected != nil and (selected.type == "RB-24J" or selected.type == "RB-74")) {
        selected.uncage_IR_seeker();
    }
}

var resetIR = func {
    if (selected != nil and (selected.type == "RB-24J" or selected.type == "RB-74")) {
        selected.reset_IR_seeker();
    }
}

# Pressing the button uncages, holding it resets
var uncageIRButtonTimer = maketimer(1, resetIR);
uncageIRButtonTimer.singleShot = TRUE;
uncageIRButtonTimer.simulatedTime = TRUE;

var uncageIRButton = func (pushed) {
    if (pushed) {
        uncageIR();
        uncageIRButtonTimer.start();
    } else {
        uncageIRButtonTimer.stop();
    }
}


# Propagate controls to weapon logic.
var trigger_listener = func (node) {
    if (selected != nil) selected.set_trigger(node.getBoolValue());
}

# Small window to display 'trigger unsafe' message.
var safety_window = screen.window.new(x:nil, y:-15, maxlines:1, autoscroll:0);

var safety_window_clear_timer = maketimer(3, func { safety_window.clear(); });
safety_window_clear_timer.singleShot = TRUE;

var unsafe_listener = func (node) {
    var unsafe = node.getBoolValue();
    if (selected != nil) selected.set_unsafe(unsafe);

    # Reminder message
    if (unsafe) {
        safety_window.write("Trigger unsafe", 1, 0, 0);
        safety_window_clear_timer.stop();
    } else {
        safety_window.write("Trigger safe", 0, 0, 1);
        safety_window_clear_timer.start();
    }
}

setlistener(input.trigger, trigger_listener, 0, 0);
setlistener(input.unsafe, unsafe_listener, 0, 0);


### Fire control inhibit.
var firing_enabled = func {
    return input.gear_pos.getValue() == 0 and power.prop.acSecond.getBoolValue();
}

var inhibit_callback = func {
    if (selected != nil and selected.armed() and firing_enabled()) selected.set_unsafe(FALSE);
}

setlistener(input.gear_pos, inhibit_callback, 0, 0);
setlistener(power.prop.acSecond, inhibit_callback, 0, 0);


### Reset fire control logic when reloading.
var ReloadCallback = {
    updateAll: func {
        _deselect_current();
        _set_selected_index(-1);
    },

    init: func {
        foreach(var station; pylons.stations_list) {
            pylons.station_by_id(station).setPylonListener(me);
        }
    },
};

ReloadCallback.init();
