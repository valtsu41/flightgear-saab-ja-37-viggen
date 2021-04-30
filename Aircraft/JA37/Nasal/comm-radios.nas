var TRUE = 1;
var FALSE = 0;

var input = {
    radio_mode:         "instrumentation/radio/mode",
    freq_sel_10mhz:     "instrumentation/radio/frequency-selector/frequency-10mhz",
    freq_sel_1mhz:      "instrumentation/radio/frequency-selector/frequency-1mhz",
    freq_sel_100khz:    "instrumentation/radio/frequency-selector/frequency-100khz",
    freq_sel_1khz:      "instrumentation/radio/frequency-selector/frequency-1khz",
    preset_file:        "ja37/radio/channels-file",
    preset_group_file:  "ja37/radio/group-channels-file",
    preset_base_file:   "ja37/radio/base-channels-file",
    gui_file:           "sim/gui/dialogs/comm-channels/channels-file",
    gui_group_file:     "sim/gui/dialogs/comm-channels/group-channels-file",
    gui_base_file:      "sim/gui/dialogs/comm-channels/base-channels-file",
};

foreach (var name; keys(input)) {
    input[name] = props.globals.getNode(input[name], 1);
}


# Convert a string to a prop. Do nothing if the input is not a string.
var ensure_prop = func(path) {
    if (typeof(path) == "scalar") return props.globals.getNode(path, 1);
    else return path;
}



#### API for comm radio frequency properties.

### Interface to set frequency for a comm radio.
#
# Takes care of
# - validating the frequency (band and separation checks)
# - updating the 'uhf' property, in turned used by JSBSim for transmission power.
var comm_radio = {
    # Arguments:
    # - path:   Property or property path to the radio, typically "instrumentation/comm[i]".
    # - vhf:    A hash {min, max, sep} indicating VHF band parameters
    #           (min/max frequencies inclusive, and separation, all KHz).
    #           Can be nil if the VHF band is not supported.
    # - uhf:    Same as 'vhf' for the UHF band.
    new: func(node, vhf, uhf) {
        var r = { parents: [comm_radio], vhf: vhf, uhf: uhf, };
        r.node = ensure_prop(node);
        r.uhf_node = r.node.getNode("uhf", 1);
        r.freq_node = r.node.getNode("frequencies/selected-mhz", 1);
        return r;
    },

    # Test if frequency is correct for a band.
    # - freq: frequency in KHz
    # - band: band object or nil, cf. vhf/uhf in new().
    is_in_band: func(freq, band) {
        if (band == nil) return FALSE;
        if (freq < band.min or freq > band.max) return FALSE;
        return math.mod(freq, band.sep) == 0;
    },

    is_VHF: func(freq) { return me.is_in_band(freq, me.vhf); },
    is_UHF: func(freq) { return me.is_in_band(freq, me.uhf); },

    is_valid_freq: func(freq) { return me.is_VHF(freq) or me.is_UHF(freq); },

    set_freq: func(freq) {
        if (!me.is_valid_freq(freq)) {
            me.freq_node.setValue(-1);
            return;
        }

        me.freq_node.setValue(freq/1000.0);
        me.uhf_node.setValue(me.is_UHF(freq));
    }
};


### The radios for each variant.

if (variant.JA) {
    # FR28 tranciever for FR29 main radio
    var fr28 = comm_radio.new(
        "instrumentation/comm[0]",
        # Values from JA37D SFI chap 19
        {min: 103000, max:159975, sep: 25},
        {min: 225000, max:399975, sep: 25});
    # FR31 secondary radio
    var fr31 = comm_radio.new(
        "instrumentation/comm[1]",
        {min: 104000, max:161975, sep: 25},
        {min: 223000, max:407975, sep: 25});
} else {
    # FR22 main radio
    var fr22 = comm_radio.new(
        "instrumentation/comm[0]",
        {min: 103000, max:155975, sep: 25},     # VHF stops at 155.975MHz, not a typo
        {min: 225000, max:399950, sep: 50});
    # FR24 backup radio
    var fr24 = comm_radio.new(
        "instrumentation/comm[1]",
        {min: 110000, max:147000, sep: 50},     # src: Militär flygradio 1916-1990, Lars V Larsson
        nil);
}



#### Channels preset file parser

## Character type functions.

var is_digit = func(c) {
    # nasal characters are numbers (ASCII code)...
    # I don't know a way to make this more readable.
    return c >= 48 and c <= 57;
}

# Space or tab
var is_whitespace = func(c) {
    return c == 32 or c == 9;
}


var Channels = {
    ## Channels table
    channels: {
        # Global fixed channels.
        # Randomly chosen, no idea what were the historical channels.
        E: 127000,
        F: 118500,
        G: 125500,
        # Guard, don't change this one.
        H: 121500,
    },


    ## Channel names

    # Suffixes for airbase channel names
    base_channel_names: ["A", "B", "C", "C2", "D"],
    # Global configurable channels
    special_channels: ["M", "L", "S1", "S2", "S3"],

    # ASCII characters for prefixes
    base_prefix: 66,    # 'B'
    group_prefix: 78,   # 'N'

    # Test if 'str' is a valid group channel name. Also include the special channels.
    is_group_channel: func(str) {
        foreach (var channel; me.special_channels) {
            if (str == channel) return TRUE;
        }

        if (size(str) != 4) return FALSE;
        if (str[0] != me.group_prefix) return FALSE;
        for (var i=1; i<4; i+=1) {
            if (!is_digit(str[i])) return FALSE;
        }
        return TRUE;
    },

    # Test if 'str' is a valid airbase channel name.
    is_base_channel: func(str) {
        if (size(str) != 4 and size(str) != 5) return FALSE;
        if (str[0] != me.base_prefix) return FALSE;
        for (var i=1; i<3; i+=1) {
            if (!is_digit(str[i])) return FALSE;
        }

        var suffix = substr(str, 3);
        foreach (var channel; me.base_channel_names) {
            if (suffix == channel) return TRUE;
        }
        return FALSE;
    },

    # Test if 'str' is an airbase or group name, which should be silently ignored
    # in the radio config file (used to add 'comments' for airbases or groups).
    is_comment_key: func(str) {
        return size(str) == 3
            and (str[0] == me.group_prefix or str[0] == me.base_prefix)
            and is_digit(str[1]) and is_digit(str[2]);
    },


    ## Parser

    # Parse a line, extract key (first whitespace separated token) and value (rest of line).
    # Comments starting with '#' are allowed.
    # Returns nil if the line is blank, [key,val] otherwise.
    # 'key' is a non-empty string without whitespace.
    # 'val' is a possibly empty string with whitespace stripped at both ends.
    parse_key_val: func(line) {
        # Strip comments
        var comment = find("#", line);
        if (comment >= 0) line = substr(line, 0, comment);
        var len = size(line);

        # Start of key
        var key_s = 0;
        while (key_s < len and is_whitespace(line[key_s])) key_s += 1;
        if (key_s >= len) return nil;
        # End of key
        var key_e = key_s;
        while (key_e < len and !is_whitespace(line[key_e])) key_e += 1;
        var key = substr(line, key_s, key_e-key_s);

        # Start of value
        var val_s = key_e;
        while (val_s < len and is_whitespace(line[val_s])) val_s += 1;
        if (val_s >= len) return [key, ""];
        # End of value
        var val_e = len;
        while (is_whitespace(line[val_e-1])) val_e -= 1;
        var val = substr(line, val_s, val_e-val_s);

        return [key,val];
    },

    # Parse a frequency string, return its value in KHz, or nil if it is invalid.
    parse_freq: func(str) {
        var f = num(str);
        if (f == nil) return nil;
        else return f * 1000.0;
    },

    # Clear channels table
    reset_channels: func(reset_group_channels=1, reset_base_channels=1) {
        foreach (var channel; keys(me.channels)) {
            if ((reset_group_channels and me.is_group_channel(channel))
                or (reset_base_channels and me.is_base_channel(channel))) {
                delete(me.channels, channel);
            }
        }
    },

    # Load a radio channels configuration file.
    read_file: func(path, load_group_channels=1, load_base_channels=1) {
        var file = nil;
        call(func { file = io.open(path, "r"); }, nil, nil, nil, var err = []);
        if (size(err)) {
            debug.printerror(err);
            printf("Failed to load radio channels file: %s\n", path);
            if (file != nil) io.close(file);
            return;
        }
        printf("Reading radio channels file %s\n", path);

        # Memorize loaded file paths, for GUI only.
        var short_path = path;
        if (size(short_path) > 50) {
            short_path = "... "~substr(short_path, size(short_path)-46);
        }
        if (load_group_channels and load_base_channels) {
            input.gui_file.setValue(short_path);
            input.gui_group_file.clearValue();
            input.gui_base_file.clearValue();
        } elsif (load_group_channels) {
            input.gui_group_file.setValue(short_path);
            if (input.gui_base_file.getValue() == nil and input.gui_file.getValue() != nil) {
                input.gui_base_file.setValue(input.gui_file.getValue());
            }
            input.gui_file.clearValue();
        } elsif (load_base_channels) {
            input.gui_base_file.setValue(short_path);
            if (input.gui_group_file.getValue() == nil and input.gui_file.getValue() != nil) {
                input.gui_group_file.setValue(input.gui_file.getValue());
            }
            input.gui_file.clearValue();
        }


        me.reset_channels(load_group_channels, load_base_channels);

        # Variables for me.parser_log
        var line_no = 0;

        while ((var line = io.readln(file)) != nil) {
            # Extract key and value from line
            line_no += 1;
            var res = me.parse_key_val(line);
            if (res == nil) continue;

            # 'Comment' key, skip
            if (me.is_comment_key(res[0])) continue;

            var is_group = me.is_group_channel(res[0]);
            var is_base = me.is_base_channel(res[0]);

            # Invalid channel name
            if (!is_group and !is_base) {
                printf("%s:%d: Warning: Ignoring unexpected channel name: %s", path, line_no, res[0]);
                continue;
            }
            # Skipped channel type.
            if ((is_group and !load_group_channels) or (is_base and !load_base_channels)) {
                printf("%s:%d: Skipping %s channel %s (only loading %s channels)",
                       path, line_no, is_group ? "group" : "base", res[0], is_group ? "base" : "group");
                continue;
            }
            # Warnings for redefined channels.
            if (contains(me.channels, res[0])) {
                printf("%s:%d: Warning: Redefinition of channel %s", path, line_no, res[0]);
            }
            # Parse and assign new frequency.
            var freq = me.parse_freq(res[1]);
            if (freq == nil) {
                printf("%s:%d: Warning: Ignoring invalid frequency: %s", path, line_no, res[1]);
                continue;
            }
            me.channels[res[0]] = freq;
        }

        io.close(file);
    },

    read_group_file: func(path) {
        me.read_file(path:path, load_base_channels:0);
    },

    read_base_file: func(path) {
        me.read_file(path:path, load_group_channels:0);
    },

    ## Channel access functions

    get: func(channel) {
        if (contains(me.channels, channel)) return me.channels[channel];
        else return 0;
    },

    get_group: func(channel) {
        return me.get("N"~channel);
    },

    get_base: func(channel) {
        return me.get("B"~channel);
    },

    guard: func() {
        return me.get("H");
    },
};



#### Radio buttons system for 3D model
#
# Controls an array of button boolean properties, ensuring that at most one of them is true at a time.
# An additional control property indicates the index of the true property (-1 if none).
# Both the button and control properties can be written, with the expected effect.
# The value of the control property is used to initialise all button properties.
var RadioButtons = {
    # Args:
    # - button_props:
    #   * Either an array of properties/property paths corresponding to the buttons.
    #     In this case values of 'control_prop' refer to the index in this array.
    #
    #   * Or a single property/property path, in which case the button properties are
    #     button_props[0] .. button_props[n_buttons-1]
    #     If button_props already has an index, say button_props[i],
    #     then it is used as an offset, i.e. the button properties are
    #     button_props[i] .. button_props[i+n_buttons-1]
    #     In this case values of 'control_prop' refer to property indices,
    #     i.e. will range from i to i+n_buttons-1 in the last example.
    #
    # - control_prop: The control property or property path.
    # - n_buttons: The number of button properties, only used if button_props is a single property.
    #              (if button_props is an array, the size of this array is used instead).
    new: func(button_props, control_prop, n_buttons=nil) {
        var b = { parents: [radio_buttons], };
        b.init(button_props, control_prop, n_buttons);
        return b;
    },

    init: func(button_props, control_prop, n_buttons) {
        me.control_prop = ensure_prop(control_prop);

        if (typeof(button_props) == "vector") {
            me.n_buttons = size(button_props);
            me.control_prop_offset = 0;
            me.button_props = [];
            setsize(me.button_props, me.n_buttons);
            forindex (var i; me.button_props) me.button_props[i] = ensure_prop(button_props[i]);
        } else {
            me.n_buttons = n_buttons;
            button_props = ensure_prop(button_props);
            var parent = button_props.getParent();
            var name = button_props.getName();
            me.control_prop_offset = button_props.getIndex();
            me.button_props = [];
            setsize(me.button_props, me.n_buttons);
            forindex (var i; me.button_props) {
                me.button_props[i] = parent.getChild(name, i+me.control_prop_offset, 1);
            }
        }

        foreach (var button; me.button_props) button.setBoolValue(FALSE);
        me.current_button = -1;

        # Property to break callbacks triggering further callbacks.
        me.inhibit_callback = FALSE;


        # Setup all the listeners
        me.button_listeners = [];
        setsize(me.button_listeners, me.n_buttons);
        forindex (var i; me.button_listeners) {
            me.button_listeners[i] = me.make_button_listener(i);
        }

        me.control_listener = setlistener(me.control_prop, func (node) {
            me.control_callback(node.getValue());
        }, 0, 0);

        # Trigger callback to set initial state
        var val = int(me.control_prop.getValue());
        if (val == nil) val = -1;
        me.control_callback(val);
    },

    del: func {
        foreach (var l; me.button_listeners) removelistener(l);
        removelistener(me.control_listener);
    },

    make_button_listener: func(idx) {
        return setlistener(me.button_props[idx], func (node) {
            me.button_callback(idx, node.getValue());
        }, 0, 0);
    },

    control_callback: func(val) {
        if (me.inhibit_callback) return;

        # Remove offset, normalise to -1 if not in range.
        var idx = val - me.control_prop_offset;
        if (idx < 0 or idx >= me.n_buttons) idx = -1;

        if (idx == me.current_button) return;

        me.inhibit_callback = TRUE;

        # Release old button if any
        if (me.current_button >= 0) me.button_props[me.current_button].setBoolValue(FALSE);
        me.current_button = idx;
        # Press new button
        if (idx >= 0) me.button_props[val].setBoolValue(TRUE);

        # Correct control property to -1 if needed.
        if (idx == -1 and val != -1) me.control_prop.setValue(-1);

        me.inhibit_callback = FALSE;
    },

    button_callback: func(idx, val) {
        if (me.inhibit_callback) return;

        # Button unchanged
        if (val and idx == me.current_button) return;
        if (!val and idx != me.current_button) return;

        me.inhibit_callback = TRUE;
        if (val) {
            # New button pressed. Release old one and update control property.
            if (me.current_button >= 0) me.button_props[me.current_button].setBoolValue(FALSE);
            me.current_button = idx;
            me.control_prop.setValue(idx + me.control_prop_offset);
        } else {
            # Current button released. Set control property to -1.
            me.current_button = -1;
            me.control_prop.setValue(-1);
        }
        me.inhibit_callback = FALSE;
    },

    set_button: func(idx) {
        me.control_prop.setValue(idx);
    },
};




# FR29 / FR22 mode knob
var MODE = {
    NORM_LARM: 0,
    NORM: 1,
    E: 2,
    F: 3,
    G: 4,
    H: 5,
    M: 6,
    L: 7,
};


### Frequency update functions.

if (variant.AJS) {
    # FR22 frequency is controlled by the FR22 channel and frequency panels.
    # Currently only the latter exists.
    var update_fr22_freq = func {
        fr22.set_freq(
            input.freq_sel_10mhz.getValue() * 10000
            + input.freq_sel_1mhz.getValue() * 1000
            + input.freq_sel_100khz.getValue() * 100
            + input.freq_sel_1khz.getValue());
    }

    setlistener(input.freq_sel_10mhz, update_fr22_freq, 0, 0);
    setlistener(input.freq_sel_1mhz, update_fr22_freq, 0, 0);
    setlistener(input.freq_sel_100khz, update_fr22_freq, 0, 0);
    setlistener(input.freq_sel_1khz, update_fr22_freq, 0, 0);

    # FR24 frequency is controlled by the FR24 mode knob
    var update_fr24_freq = func {
        var mode = input.radio_mode.getValue();
        var freq = 0;

        if (mode == MODE.NORM_LARM) {
            freq = Channels.guard();
        } else {
            foreach (var chan; ["E", "F", "G", "H"]) {
                if (mode == MODE[chan]) freq = Channels.get(chan);
            }
        }

        fr24.set_freq(freq);
    }

    setlistener(input.radio_mode, update_fr24_freq, 0, 0);
}


var default_group_channels = getprop("/sim/aircraft-dir")~"/Nasal/channels-default.txt";

var init = func {
    var path = input.preset_file.getValue();
    var group_path = input.preset_group_file.getValue();
    var base_path = input.preset_base_file.getValue();

    # Load default channels configuration
    if (path == nil and group_path == nil) {
        Channels.read_group_file(default_group_channels);
    }
    # Load custom ones
    if (path != nil and (group_path == nil or base_path == nil)) {
        Channels.read_file(path);
    }
    if (group_path != nil) {
        Channels.read_group_file(group_path);
    }
    if (base_path != nil) {
        Channels.read_base_file(base_path);
    }


    if (variant.AJS) {
        update_fr22_freq();
        update_fr24_freq();
    }
}
