package nmsynth

import ma "vendor:miniaudio"
import "core:fmt"
import "core:os"

NUM_CHANNELS :: 2
SAMPLE_RATE :: 48000

Synth :: struct {
	// User State
}

data_callback :: proc "c" (device: ^ma.device, output: rawptr, input: rawptr, frame_count: u32) {
	// In playback mode copy data to pOutput. In capture mode read data from pInput. In full-duplex mode, both
    // pOutput and pInput will be valid and you can move data from pInput into pOutput. Never process more than
    // frameCount frames.
    // 				-- from miniaudio docs

}


main :: proc() {
	synth : Synth

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

	device : ma.device
	res : ma.result = ma.device_init(nil, &device_config, &device)
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

}
