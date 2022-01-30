#### JA 37D PS/46A radar
#
# Based on Nikolai V. Chr. F-16 radar

var FALSE = 0;
var TRUE = 1;

var input = {
    radar_serv:         "instrumentation/radar/serviceable",
    antenna_angle:      "instrumentation/radar/antenna-angle-norm",
    nose_wow:           "fdm/jsbsim/gear/unit[0]/WOW",
    gear_pos:           "gear/gear/position-norm",
};

foreach(var name; keys(input)) {
    input[name] = props.globals.getNode(input[name], 1);
};


### Radar parameters (used as subclass of AirborneRadar from radar.nas)

var PS46 = {
    # need source for all of these
    fieldOfRegardMaxAz: 60,     # to match MI
    fieldOfRegardMaxElev: 60,
    instantFoVradius: 2.0,
    instantVertFoVradius: 2.5,  # unused (could be used by ground mapper)
    instantHoriFoVradius: 1.5,  # unused
    rcsRefDistance: 40,
    rcsRefValue: 3.2,
    maxTilt: 60,

    # If radar get turned off by WoW (or failure) it stays off.
    isEnabled: func {
        return me.enabled and input.radar_serv.getBoolValue()
          and !input.nose_wow.getBoolValue() and power.prop.hyd1Bool.getBoolValue()
          and power.prop.dcSecondBool.getBoolValue() and power.prop.acSecondBool.getBoolValue();
    },

    enable: func {
        me.enabled = 1;
        me.enabled = me.isEnabled();
    },
    disable: func {
        me.enabled = 0;
    },
    toggle: func {
        if (me.enabled) me.disable();
        else me.enable();
    },

    getTiltKnob: func {
        return input.antenna_angle.getValue() * 10;
    },

    # Similar to setCurrentMode, but remembers current target and range
    setMode: func(newMode, priority=nil, old_priority=0) {
        newMode.setRange(me.currentMode.getRange());
        if (priority == nil and old_priority) priority = me.currentMode["priorityTarget"];
        me.currentMode.leaveMode();
        me.setCurrentMode(newMode, priority);
    },

    isTracking: func(contact) {
        return me.currentMode.isTracking(contact);
    },

    isPrimary: func(contact) {
        return contact.equals(me.getPriorityTarget());
    },
};


### Parent class for PS/46 modes

var PS46Mode = {
    parents: [RadarMode],

    radar: nil,

    # ranges in meter (unlike generic RadarMode)
    minRangeM: 15000,
    maxRangeM: 120000,
    rangeM: 60000,
    # make sure these are never used
    minRange: nil,
    maxRange: nil,
    range: nil,

    rcsFactor: 1,

    rootName: "PS46",
    shortName: "",
    longName: "",


    setRangeM: func (range) {
        if (range < me.minRangeM or range > me.maxRangeM or math.mod(range, me.minRangeM) != 0) return 0;

        me.rangeM = range;
        return 1;
    },
    getRangeM: func {
        return me.rangeM;
    },

    # These _must_ be in NM (used by the rest of the code)
    setRange: func (range) {
        me.setRangeM(int(range * NM2M));
    },
    getRange: func {
        return me.rangeM * M2NM;
    },

    _increaseRange: func {
        if (me.rangeM <= me.maxRangeM/2) {
            me.rangeM *= 2;
            return 1;
        } else {
            return 0;
        }
    },
    _decreaseRange: func {
        if (me.rangeM >= me.minRangeM*2) {
            me.rangeM /= 2;
            return 1;
        } else {
            return 0;
        }
    },
    increaseRange: func {
        return me._increaseRange();
    },
    decreaseRange: func {
        return me._decreaseRange();
    },

    setCursorDistance: func(nm) {
        me.cursorNm = math.clamp(nm, 0, me.getRange());
        return 0;
    },

    isTracking: func(contact) {
        return 0;
    },

    # Must be defined by each mode, used to set azimuth / elevation offset
    preStep: func {
        me.azimuthTilt = me.cursorAz;
        me.constrainAz();
        me.elevationTilt = me.radar.getTiltKnob();
    },

    # type of information given by this mode
    # [dist, groundtrack, deviations, speed, closing-rate, altitude]
    getSearchInfo: func (contact) {
        return [1,0,1,0,0,1];
    },
};


var ScanMode = {
    parents: [PS46Mode],

    shortName: "Scan",
    longName: "Wide Scan",

    az: 60,             # width of search (matches MI)
    discSpeed_dps: 60,  # sweep speed (estimated from MI video)

    # scan patterns
    bars: 1,            # pattern index (1 based)
    # A point is a pair [azimuth, height]. azimuth unit is me.az, height unit is me.barHeight * instantFoVradius
    # A pattern is a vector of points
    # This is a vector of patterns (one per "scan mode")
    #
    # From a MI video, the vertical scan is around 1/10 radian ~= 6deg
    barPattern: [ [[1,3],[-1,3],[-1,1],[1,1],[1,-1],[-1,-1],[-1,-3],[1,-3]] ],
    barHeight: 0.8,
    barPatternMin: [-3],
    barPatternMax: [3],

    timeToKeepBleps: 13,


    designate: func (contact) {
        if (contact == nil) return;
        STT(me, contact);
    },

    designatePriority: func (contact) {
        me.designate(contact);
    },

    undesignate: func {},

    preStep: func {
        me.azimuthTilt = 0;
        me.elevationTilt = me.radar.getTiltKnob();
    },
};


var TWSMode = {
    parents: [PS46Mode],

    shortName: "TWS",
    longName: "Track While Scan",

    az: 30,
    discSpeed_dps: 60,

    bars: 1,
    barPattern: [ [[1,0],[-1,0],[-1,2],[1,2],[1,0],[-1,0],[-1,-2],[1,-2]] ],
    barHeight: 0.8,
    barPatternMin: [-2],
    barPatternMax: [2],

    timeToKeepBleps: 13,
    max_scan_interval: 6.5,
    priorityTarget: nil,
    # Tracks, sorted from oldest to newest
    tracks: [],
    priority_index: -1,
    max_tracks: 4,


    _removeTrack: func(contact) {
        forindex (var i; me.tracks) {
            if (contact.equals(me.tracks[i])) {
                me._removeTrackIndex(i);
                return;
            }
        }
    },

    _removeTrackIndex: func(i) {
        if (i >= size(me.tracks)) return;
        var tmp = [];
        forindex (var j; me.tracks) {
            if (i == j) continue;
            append(tmp, me.tracks[j]);
        }
        me.tracks = tmp;
    },

    designate: func(contact) {
        if (contact == nil) return;

        if (contact.equals(me.priorityTarget)) {
            STT(me, contact);
            return;
        }

        forindex (var i; me.tracks) {
            if (contact.equals(me.tracks[i])) {
                me.priorityTarget = me.tracks[i];
                me.priority_index = i;
                return;
            }
        }

        if (size(me.tracks) < me.max_tracks) {
            me.priority_index = size(me.tracks);
            me.priorityTarget = contact;
            append(me.tracks, contact);
            return;
        }

        me.priority_index += 1;
        if (me.priority_index >= me.max_tracks) me.priority_index = 0;
        me.tracks[me.priority_index] = contact;
        me.priorityTarget = contact;
    },

    designatePriority: func(contact) {
        me.designate(contact);
    },

    undesignate: func {
        me.priorityTarget = nil;
        me.priority_index = -1;
    },

    prunedContact: func(contact) {
        if (contact.equals(me.priorityTarget)) {
            me.priorityTarget = nil;
            me.priority_index = -1;
        }
        me._removeTrack(contact);
    },

    leaveMode: func {
        me.tracks = [];
        me.priority_index = -1;
    },

    cycleDesignate: func {
        if (size(me.tracks) == 0) return;

        if (me.priorityTarget == nil) {
            me.priority_index = 0;
        } else {
            me.priority_index += 1;
            if (me.priority_index >= size(me.tracks)) me.priority_index = 0;
        }

        me.priorityTarget = me.tracks[me.priority_index];
    },

    preStep: func {
        if (me.priorityTarget == nil) {
            me.azimuthTilt = me.cursorAz;
            me.elevationTilt = me.radar.getTiltKnob();
            me.constrainAz();
            return;
        }

        var lastBlep = me.priorityTarget.getLastBlep();
        var range = lastBlep.getRangeNow() * M2NM;

        me.azimuthTilt = lastBlep.getAZDeviation();
        me.elevationTilt = lastBlep.getElev(); # tilt here is in relation to horizon
        me.constrainAz();

        me.cursorAz = me.azimuthTilt;
        me.cursorNm = range;
    },

    isTracking: func(contact) {
        foreach (var track; me.tracks) {
            if (contact.equals(track)) return 1;
        }
        return 0;
    },

    # type of information given by this mode
    # [dist, groundtrack, deviations, speed, closing-rate, altitude]
    getSearchInfo: func (contact) {
        foreach (var track; me.tracks) {
            if (contact.equals(track) and me.radar.elapsed - contact.getLastBlepTime() < me.max_scan_interval)
                return [1,1,1,1,1,1];
        }
        return [1,0,1,0,0,1];
    },
};


var DiskSearchMode = {
    parents: [PS46Mode],

    shortName: "Disk",
    longName: "Disk Search",

    rangeM: 15000,

    discSpeed_dps: 90,
    rcsFactor: 0.9,

    # scan patterns (~ 20x20 deg disk)
    az: 10,
    bars: 1,
    barPattern: [ [[-1,1],[1,1],[0.8,3],[-0.8,3],[-0.5,5],[0.5,5],[0.5,-5],[-0.5,-5],[-0.8,-3],[0.8,-3],[1,-1],[-1,-1]] ],
    barHeight: 0.9,
    barPatternMin: [-5],
    barPatternMax: [5],

    preStep: func {
        me.radar.horizonStabilized = 0;
        me.azimuthTilt = 0;
        me.elevationTilt = -5;
    },

    designate: func (contact) {
        if (contact == nil) return;
        STT(me, contact);
    },

    designatePriority: func (contact) {},

    undesignate: func {},

    increaseRange: func {
        return 0;
    },
    decreaseRange: func {
        return 0;
    },
    setRange: func {
        return 0;
    },

    getSearchInfo: func (contact) {
        # This gets called as soon as the radar finds something -> autolock
        me.designate(contact);
        return [1,1,1,1,1,1];
    },
};


var STTMode = {
    parents: [PS46Mode],

    shortName: "STT",
    longName: "Single Target Track",

    rcsFactor: 1.1,
    az: PS46.instantFoVradius * 0.8,

    discSpeed_dps: 90,

    # scan patterns
    bars: 1,            # pattern index (1 based)
    # A point is a pair [azimuth, height]. azimuth unit is me.az, height unit is me.barHeight * instantFoVradius
    # A pattern is a vector of points
    # This is a vector of patterns (one per "scan mode")
    barPattern: [ [[-1,-1],[1,-1],[1,1],[-1,1]] ],
    barHeight: 0.8,
    barPatternMin: [-1],
    barPatternMax: [1],

    minimumTimePerReturn: 0.10,
    timeToKeepBleps: 5,
    painter: 1,
    priorityTarget: nil,

    parent_mode: nil,

    preStep: func {
        if (me.priorityTarget == nil or me.priorityTarget.getLastBlep() == nil
            or !me.radar.containsVectorContact(me.radar.vector_aicontacts_bleps, me.priorityTarget))
        {
            me.undesignate();
            return;
        }

        var lastBlep = me.priorityTarget.getLastBlep();
        var range = lastBlep.getRangeNow() * M2NM;

        me.azimuthTilt = lastBlep.getAZDeviation();
        me.elevationTilt = lastBlep.getElev(); # tilt here is in relation to horizon
        me.constrainAz();

        me.cursorAz = me.azimuthTilt;
        me.cursorNm = range;
    },

    designate: func (contact) {},

    designatePriority: func (contact) {
        me.priorityTarget = contact;
    },

    undesignate: func {
        me.priorityTarget = nil;
        me.radar.setMode(me.parent_mode);
    },

    # Cursor is ignored (internal cursor = target)
    setCursorDistance: func(nm) {},
    setCursorDeviation: func(az) {},

    # Range logic is from parent mode
    getRange: func {
        return me.parent_mode.getRange();
    },
    setRange: func(nm) {
        return me.parent_mode.setRange(nm);
    },
    getRangeM: func {
        return me.parent_mode.getRangeM();
    },
    setRangeM: func(m) {
        return me.parent_mode.setRangeM(m);
    },
    increaseRange: func {
        return me.parent_mode.increaseRange();
    },
    decreaseRange: func {
        return me.parent_mode.decreaseRange();
    },

    isTracking: func(contact) {
        return contact.equals(me.priorityTarget);
    },

    # type of information given by this mode
    # [dist, groundtrack, deviations, speed, closing-rate, altitude]
    getSearchInfo: func (contact) {
        if (me.priorityTarget != nil and contact.equals(me.priorityTarget)) {
            return [1,1,1,1,1,1];
        }
        return nil;
    },
};



### Array of main mode, each being an array of submodes.

var ps46_modes = [
    [ScanMode],
    [TWSMode],
    [DiskSearchMode],
    [STTMode],
];

var ps46 = nil;



### Controls

# Parent mode is the current mode calling STT.
# STT mode will return to parent when losing lock.
# STT mode also uses the parent mode logic for range.
var STT = func(parent_mode, contact) {
    STTMode.parent_mode = parent_mode;
    ps46.setMode(STTMode, contact);
}


# Throttle buttons

var scan = func {
    main_mode = ScanMode;
    ps46.setMode(ScanMode);
}

var TWS = func {
    main_mode = TWSMode;
    ps46.setMode(TWSMode, nil, TRUE);   # keep track from previous mode
}

var toggle_radar_on = func {
    if (modes.main_ja == modes.AIMING) {
        # In aiming mode, this button turns radar off instead
        ps46.disable();
    } else {
        ps46.toggle();
    }
}

var disk_search = func {
    # aiming mode, radar on, disk search
    if (input.gear_pos.getValue() > 0) return;

    modes.main_ja = modes.AIMING;
    ps46.enable();
    main_mode = DiskSearchMode;
    ps46.setMode(DiskSearchMode);
}

var cycle_target = func {
    ps46.cycleDesignate();
}

var increaseRange = func {
    ps46.increaseRange();
}

var decreaseRange = func {
    ps46.decreaseRange();
}



### Initialization

var init = func {
    init_generic();
    ps46 = AirborneRadar.newAirborne(ps46_modes, PS46);
}
