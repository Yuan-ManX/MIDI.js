#!/usr/bin/env ruby
#
# JavaScript Soundfont Builder for MIDI.js
# Author: 0xFE <mohit@muthanna.com>
#
# Requires:
#
#   FluidSynth
#   Lame
#   Ruby Gems: midilib, parallel
#
#   $ brew install --with-libsndfile fluidsynth
#   $ brew install lame
#   $ gem install midilib parallel
#
# You'll need to download a GM soundbank to generate audio.
#
# Usage:
#
# 1) Install the above dependencies.
# 2) Edit BUILD_DIR, SOUNDFONT, and INSTRUMENTS as required.
# 3) Run without any argument.

require 'base64'
require 'fileutils'
require 'midilib'
require 'zlib'
require 'parallel'
include FileUtils

BUILD_DIR = "./soundfont" # Output path
SOUNDFONT = "../sf2/redco/TR-808-Drums.SF2" # Soundfont file path

# This script will generate MIDI.js-compatible instrument JS files for
# all instruments in the below array. Add or remove as necessary.
INSTRUMENTS = 0.upto(127).to_a
DRUMS = true

# The encoders and tools are expected in your PATH. You can supply alternate
# paths by changing the constants below.
LAME = `which lame`.chomp
FLUIDSYNTH = `which fluidsynth`.chomp

puts "Building the following instruments using font: " + SOUNDFONT

# Display instrument names.
INSTRUMENTS.each do |i|
  puts "    #{i}: " + MIDI::GM_PATCH_NAMES[i]
end

puts
puts "Using MP3 encoder: " + LAME
puts "Using FluidSynth encoder: " + FLUIDSYNTH
puts
puts "Sending output to: " + BUILD_DIR
puts

raise "Can't find soundfont: #{SOUNDFONT}" unless File.exists? SOUNDFONT
raise "Can't find 'lame' command" if LAME.empty?
raise "Can't find 'fluidsynth' command" if FLUIDSYNTH.empty?
raise "Output directory does not exist: #{BUILD_DIR}" unless File.exists?(BUILD_DIR)

puts "Hit return to begin."
$stdin.readline

NOTES = {
  "C"  => 0,
  "Db" => 1,
  "D"  => 2,
  "Eb" => 3,
  "E"  => 4,
  "F"  => 5,
  "Gb" => 6,
  "G"  => 7,
  "Ab" => 8,
  "A"  => 9,
  "Bb" => 10,
  "B"  => 11
}

MIDI_C0 = 12
VELOCITY = 85
DURATION = Integer(3000)
RELEASE = Integer(1000)
TEMP_FILE = "#{BUILD_DIR}/%s%stemp.midi"

MIN_DRUM = 35
MAX_DRUM = 81

def deflate(string, level)
  z = Zlib::Deflate.new(level)
  dst = z.deflate(string, Zlib::FINISH)
  z.close
  dst
end

def note_to_int(note, octave)
  value = NOTES[note]
  increment = MIDI_C0 + (octave * 12)
  return value + increment
end

def int_to_note(value)
  raise "Bad Value" if value < MIDI_C0
  reverse_notes = NOTES.invert
  value -= MIDI_C0
  octave = value / 12
  note = value % 12
  return { key: reverse_notes[note],
           octave: octave }
end

# Run a quick table validation
MIDI_C0.upto(100) do |x|
  note = int_to_note x
  raise "Broken table" unless note_to_int(note[:key], note[:octave]) == x
end

def generate_midi(channel, program, note_value, file)
  include MIDI
  seq = Sequence.new()
  track = Track.new(seq)

  seq.tracks << track
  track.events << ProgramChange.new(channel, Integer(program))
  track.events << NoteOn.new(channel, note_value, VELOCITY, 0) # channel, note, velocity, delta
  track.events << NoteOff.new(channel, note_value, VELOCITY, DURATION)
  # Add extra events to force the note release to render.
  track.events << NoteOn.new(channel, note_value, 0, RELEASE)
  track.events << NoteOff.new(channel, note_value, 0, 0)

  File.open(file, 'wb') { | file | seq.write(file) }
end

def run_command(cmd)
  puts "Running: " + cmd
  `#{cmd}`
end

def midi_to_audio(source, target)
  run_command "#{FLUIDSYNTH} -C no -R no -g 1.0 -F #{target} #{SOUNDFONT} #{source}"
  run_command "#{LAME} -v -b 8 -B 64 #{target}"
  rm target
end

def open_js_file(instrument_key)
  js_file = File.open("#{BUILD_DIR}/#{instrument_key}.js", "w")
  js_file.write(
"""
if (typeof(MIDI) === 'undefined') var MIDI = {};
if (typeof(MIDI.Soundfont) === 'undefined') MIDI.Soundfont = {};
MIDI.Soundfont.#{instrument_key} = {
""")
  return js_file
end

def close_js_file(file)
  file.write("\n}\n")
  file.close
end

def base64js(note, file, type)
  output = '"' + note + '": '
  output += '"' + "data:audio/#{type};base64,"
  output += Base64.strict_encode64(File.read(file)) + '"'
  return output
end

def generate_audio(channel, program)
  include MIDI
  if channel == 9
    instrument = "drums"
    instrument_key = "percussion"
    min_note = MIN_DRUM
    max_note = MAX_DRUM
  else
    instrument = GM_PATCH_NAMES[program]
    instrument_key = instrument.downcase.gsub(/[^a-z0-9 ]/, "").gsub(/\s+/, "_")
    min_note = note_to_int("A", 0)
    max_note = note_to_int("C", 8)
  end
  
  puts "Generating audio for: " + instrument + "(#{instrument_key})"

  mkdir_p "#{BUILD_DIR}/#{instrument_key}"
  mp3_js_file = open_js_file(instrument_key)

  min_note.upto(max_note) do |note_value|
    note = int_to_note(note_value)
    output_name = "p#{note_value}"
    output_path_prefix = BUILD_DIR + "/#{instrument_key}" + output_name

    puts "Generating: #{output_name}"
    temp_file_specific = TEMP_FILE % [output_name, instrument_key]
    generate_midi(channel, program, note_value, temp_file_specific)
    midi_to_audio(temp_file_specific, output_path_prefix + ".wav")

    puts "Updating JS files..."
    mp3_js_file.write(base64js(output_name, output_path_prefix + ".mp3", "mp3") + ",\n")

    mv output_path_prefix + ".mp3", "#{BUILD_DIR}/#{instrument_key}/#{output_name}" + ".mp3"
    rm temp_file_specific
  end

  close_js_file(mp3_js_file)
  
  mp3_js_file = File.read("#{BUILD_DIR}/#{instrument_key}.js")
  mjsz = File.open("#{BUILD_DIR}/#{instrument_key}.js.gz", "w")
  mjsz.write(deflate(mp3_js_file, 9));

end

Parallel.each(INSTRUMENTS, :in_processes=>10){|i| generate_audio(0, i)}
if DRUMS
  generate_audio(9, 0)
end