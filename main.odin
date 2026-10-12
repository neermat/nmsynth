package nmsynth

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:time"
import ma "vendor:miniaudio"

NUM_CHANNELS :: 2
SAMPLE_RATE :: 48000
MAX_SAMPLES :: 512
MAX_VOLUME :: 0.1
PLUCK_BETA :: 0.15 // 0 -> bridge, 0.5 -> middle of string


NUM_HARMONICS :: 10
AMP_PEAK :: 0.7
ATTACK :: 0.002
// TODO: fix glitch around attack - decay transition
DECAY_B1 :: 1
DECAY_B3 :: 3e-6

StereoSample :: [2]f32
Buffer :: struct {
	data: [MAX_SAMPLES]StereoSample,
}

Synth :: struct {
	// User State
	buffer:     Buffer,
	time:       f64,
	max_vol:    f32,
	pluck_beta: f32,
	// decay model for nth harmonic : 1/tau_n = decay_b1 + decay_b3 * freq(n)^2
	decay_b1:   f32, // in 1/s (overall decay)
	decay_b3:   f32, // in s (b3=0 -> all harmonics decay at same rate)
	voices:     []Voice,
}

Voice :: struct {
	freq:        f32,
	phase:       f32,
	time_offset: f64,
	amp:         f32,
	amp_peak:    f32,
	attack:      f32,
	// attack: linear ramp to amp_peak
	decay_inv:   f32,
	// decay: duration when sound attenuates to 1/e = 37%
	is_active:   bool,
}

// NOTE: Alive for duration of frame_count samples
VoiceState :: struct {
	v_id:             int,
	afps:             f32,
	voice_time:       f64,
	attack_amp_coeff: f32,
	decay_per_sample: f32,
}

data_callback :: proc "c" (device: ^ma.device, output: rawptr, input: rawptr, frame_count: u32) {
	// Never process more than frameCount frames.
	// 				-- from miniaudio docs
	synth := (^Synth)(device.pUserData)
	// if !synth.is_active do return
	context = runtime.default_context()
	sr := f32(device.sampleRate)
	mix_val: f32
	output_t := ([^]StereoSample)(output)
	time_step: f64 = 1 / f64(sr)
	voice_states := make([]VoiceState, len(synth.voices))
	defer delete(voice_states)
	for i in 0 ..< frame_count {
		// Update all voices
		val: f32
		for &voice, v_id in synth.voices {
			voice_val: f32
			if i == 0 {
				voice_states[v_id].v_id = v_id
				voice_states[v_id].afps = math.TAU * voice.freq / sr
				voice_states[v_id].attack_amp_coeff = voice.amp_peak / voice.attack
				voice_states[v_id].decay_per_sample = 1 - voice.decay_inv / sr
				if voice.phase > math.TAU {
					voice.phase -= math.TAU
				}
			}
			voice_state := voice_states[v_id]
			if !voice.is_active {
				voice_val = 0
				continue
			}
			voice_state.voice_time = voice.time_offset + synth.time
			voice_val = voice.amp * math.sin(voice.phase)
			voice.phase += voice_state.afps
			if f32(voice_state.voice_time) < voice.attack {
				voice.amp = voice_state.attack_amp_coeff * f32(voice_state.voice_time)
			} else {
				voice.amp *= voice_state.decay_per_sample
				if voice.amp < 1e-5 {
					voice.amp = 0
					voice.is_active = false
				}
			}
			val += voice_val
		}
		// Update at synth-level
		val = math.clamp(val, -synth.max_vol, synth.max_vol)
		output_t[i].x = val
		output_t[i].y = val
		synth.time += time_step
	}

}


guitar_synth_setup :: proc(synth: ^Synth, fundamental_freq: f32, amp_peak: f32, attack: f32) {
	synth.time = 0
	harm_freq: f32
	for i in 0 ..< len(synth.voices) {
		n := i + 1
		harm_freq = f32(n) * fundamental_freq
		synth.voices[i] = Voice {
			freq        = harm_freq,
			phase       = 0,
			time_offset = 0,
			amp         = 0,
			amp_peak    = math.sin(
				f32(n) * math.PI * synth.pluck_beta,
			) * amp_peak / (f32(n) * f32(n) * math.sin(math.PI * synth.pluck_beta)),
			attack      = attack,
			decay_inv   = synth.decay_b1 + synth.decay_b3 * harm_freq * harm_freq,
			is_active   = true,
		}
	}
}


main :: proc() {
	synth: Synth = {
		buffer     = Buffer{},
		max_vol    = MAX_VOLUME,
		pluck_beta = PLUCK_BETA,
		decay_b1   = DECAY_B1,
		decay_b3   = DECAY_B3,
	}
	voices: [NUM_HARMONICS]Voice
	synth.voices = voices[:]

	// The frequency at which data is delivered to and from a device depends on the
	// size of its period. The size of the period can be defined in terms of PCM frames
	// or milliseconds, whichever is more convenient.
	// Generally speaking, the smaller the period, the lower the latency at the expense of
	// higher CPU usage and increased risk of glitching due to the more frequent and granular
	// data deliver intervals. The size of a period will depend on your requirements, but
	// miniaudio’s defaults should work fine for most scenarios. If you’re building a game
	// you should leave this fairly small, whereas if you’re building a simple media player
	// you can make it larger. Note that the period size you request is actually just a hint
	// - miniaudio will tell the backend what you want, but the backend is ultimately responsible
	//  for what it gives you. You cannot assume you will get exactly what you ask for.
	// 			-- from miniaudio doc

	device_config := ma.device_config_init(.playback)
	device_config.playback.format = .f32
	device_config.playback.channels = NUM_CHANNELS
	device_config.sampleRate = SAMPLE_RATE
	device_config.dataCallback = data_callback
	device_config.pUserData = &synth

	device: ma.device
	res: ma.result = ma.device_init(nil, &device_config, &device)
	if res != .SUCCESS {
		fmt.eprintfln("Could not open playback device. Result: [%v]", res)
		os.exit(-1)
	}
	defer ma.device_uninit(&device)
	fmt.printfln("Backend: %s, Playback device: %s", device.pContext.backend, device.playback.name)


	res = ma.device_start(&device)
	if res != .SUCCESS {
		fmt.eprintfln("Failed to start playback device. Result: [%v]", res)
		os.exit(-1)
	}
	defer ma.device_stop(&device)


	// Program logic here:
	// Sweep
	// NOTE: STALE
	// max_tone :: 15_000
	// tone_freq: f32 = 30
	// play_sweep: bool
	// if play_sweep {
	// 	for tone_freq < max_tone {
	// 		fmt.printfln("Playing tone : %.0f Hz", tone_freq)
	// 		synth.freq = tone_freq
	// 		tone_freq *= 1.1
	// 		time.sleep(0.1 * 1e9)
	// 	}
	// }

	// Musical Scales
	semitone: f32 = math.pow_f32(2, f32(1 / 12.0))
	chromatic_scale_freqs: [12]f32
	chromatic_scale_freqs[0] = 55
	for i in 1 ..< len(chromatic_scale_freqs) {
		chromatic_scale_freqs[i] = chromatic_scale_freqs[i - 1] * semitone
	}

	// major_scale: [7]int = {0, 2, 4, 5, 7, 9, 11}
	MajorScaleDegree :: enum {
		TONIC   = 0,
		SECOND  = 2,
		THIRD   = 4,
		FOURTH  = 5,
		FIFTH   = 7,
		SIXTH   = 7,
		SEVENTH = 9,
	}


	octave_factors: [5]f32 = {1, 2, 4, 8, 16}

	beat_type: [3]f32 = {0.25, 0.25, 0.5}
	beat_duration: f32 = 1.0

	num_octaves :: 4
	note: MajorScaleDegree
	octave: int
	note_dur: f32
	note_dur_ns: time.Duration
	for {
		note = rand.choice_enum(MajorScaleDegree)
		octave = rand.int_range(0, num_octaves)
		note_dur = rand.choice(beat_type[:]) * beat_duration
		note_dur_ns = time.Duration(note_dur * 1e9)
		// set synth frequency
		freq := chromatic_scale_freqs[note] * octave_factors[octave]
		guitar_synth_setup(&synth, freq, AMP_PEAK, ATTACK)
		fmt.printfln("Note: %v, Octave: %d", note, octave)
		time.sleep(note_dur_ns)
	}

}
