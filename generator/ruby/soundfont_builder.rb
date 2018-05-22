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
require 'parallel'
include FileUtils
include MIDI

NAME = "sgm_v85_piano_drums"

BUILD_DIR = "./soundfonts/#{NAME}" # Output path
SOUNDFONT = "../sf2/redco/TR-808-Drums.SF2" # Soundfont file path

# This script will generate MP3 files for all instruments in the below array.
# Add or remove as necessary.
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
if DRUMS
  puts "    drums: percussion"
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
VELOCITIES = [85]
DURATION = Integer(3000)
RELEASE = Integer(1000)
TEMP_FILE = "#{BUILD_DIR}/%s_%s.midi"

MIN_DRUM = 35
MAX_DRUM = 81

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

def generate_midi(channel, program, note_value, velocity, file)
  seq = Sequence.new()
  track = Track.new(seq)

  seq.tracks << track
  track.events << ProgramChange.new(channel, Integer(program))
  track.events << NoteOn.new(channel, note_value, velocity, 0) # channel, note, velocity, delta
  track.events << NoteOff.new(channel, note_value, velocity, DURATION)
  # Add extra event to force the note release to render.
  track.events << NoteOn.new(channel, note_value, 0, RELEASE)

  File.open(file, 'wb') { | file | seq.write(file) }
end

def run_command(cmd)
  puts "Running: " + cmd
  `#{cmd}`
end

def midi_to_audio(source, target)
  run_command "#{FLUIDSYNTH} -C no -R no -g 1.0 -F #{target} #{SOUNDFONT} #{source}"
  run_command "#{LAME} -v -b 8 -B 64 --replaygain-accurate #{target}"
  rm target
end

def write_json_file(instrument_key, min_note, max_note)
  json_file = File.open("#{BUILD_DIR}/#{instrument_key}/instrument.json", "w")
  json_file.write("{")
  json_file.write(%Q(
  "name": "#{instrument_key}",
  "minPitch": #{min_note},
  "maxPitch": #{max_note},
  "durationSeconds": #{DURATION / 1000.0},
  "releaseSeconds": #{RELEASE / 1000.0}))
  if VELOCITIES.length > 1
    velocities_str = VELOCITIES.map {|v| v.to_s}.join(", ")
    json_file.write(",\n")
    json_file.write("  \"velocities\": [#{velocities_str}]")
  end
  json_file.write("\n}\n")
  json_file.close
end

def generate_audio(channel, program)
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

  min_note.upto(max_note) do |note_value|
    VELOCITIES.each do |velocity|
      note = int_to_note(note_value)
      output_name = "p#{note_value}"
      if VELOCITIES.length > 1
        output_name << "_v#{velocity}"
      end
      output_path_prefix = BUILD_DIR + "/#{instrument_key}_#{output_name}"

      puts "Generating: #{output_name}"
      temp_file_specific = TEMP_FILE % [instrument_key, output_name]
      generate_midi(channel, program, note_value, velocity, temp_file_specific)
      midi_to_audio(temp_file_specific, output_path_prefix + ".wav")

      mv output_path_prefix + ".mp3", "#{BUILD_DIR}/#{instrument_key}/#{output_name}" + ".mp3"
      rm temp_file_specific
    end
  end
  
  write_json_file(instrument_key, min_note, max_note)

end

Parallel.each(INSTRUMENTS, :in_processes=>10){|i| generate_audio(0, i)}
if DRUMS
  generate_audio(9, 0)
end

# Write a JSON file mapping program number to instrument name.
json_file = File.open("#{BUILD_DIR}/soundfont.json", "w")
json_file.write("{\n")
json_file.write("  \"name\": \"#{NAME}\",\n")
json_file.write("  \"instruments\": {\n")
INSTRUMENTS.each do |i|
  instrument = GM_PATCH_NAMES[i]
  instrument_key = instrument.downcase.gsub(/[^a-z0-9 ]/, "").gsub(/\s+/, "_")
  json_file.write("    \"#{i}\": \"#{instrument_key}\",\n")
end
if DRUMS
  json_file.write("    \"drums\": \"percussion\"\n")
end
json_file.write("  }\n")
json_file.write("}\n")
json_file.close
