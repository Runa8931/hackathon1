// =============================================
// Processing プログラム（ギター担当）シリアル通信対応修正版
// Minimライブラリ使用・Karplus-Strong実装版
// シリアル通信：1=1拍進める, 0=停止
//
// [修正点] guitar_processing_3.pde の音を再現するため以下を変更：
//   1. ksDelay の係数を 1.1 → 1.6 に戻す（音程・音色の復元）
//   2. 倍音付加の基準周波数を frequency/1.6 の lowFreq に戻す（音色の復元）
//   3. RELEASE_MS を復活させ、サンプル長と ADSR の release を動的計算に戻す（余韻の復元）
// =============================================

import processing.serial.*;
import ddf.minim.*;
import ddf.minim.ugens.*;

Serial myPort;
Minim minim;
AudioOutput output;

float currentFrequency = 0;
float currentBeatLen   = 1.0;

final int BPM = 160;

// [修正1] 余韻時間を guitar_processing_3 に合わせて復活
final int RELEASE_MS = 800;

// 楽譜データ
final int NOTE_COUNT = 52;
float[] noteArray = {
  523.3, 587.3, 523.3, 587.3, 523.3,
  440.0, 440.0, 466.2, 440.0, 466.2,
  440.0, 349.2, 440.0, 349.2, 392.0,
  440.0, 349.2, 392.0, 440.0, 466.2,
  523.3, 523.3, 392.0, 440.0, 392.0,
  523.3, 587.3, 523.3, 587.3, 523.3,
  523.3, 440.0, 440.0, 440.0, 466.2,
  440.0, 466.2, 440.0, 440.0, 349.2,
  587.3, 523.3, 440.0, 523.3, 523.3,
  440.0, 349.2, 440.0, 440.0, 392.0,
  392.0, 349.2
};
float[] beatArray = {
  0.75, 0.25, 0.75, 0.25, 1.0,
  1.0,  0.75, 0.25, 0.75, 0.25,
  1.0,  1.0,  1.0,  0.5,  0.5,
  1.0,  0.5,  0.5,  0.75, 0.25,
  0.5,  0.5,  0.75, 0.25, 1.0,
  0.75, 0.25, 0.75, 0.25, 0.5,
  0.5,  0.5,  0.5,  0.75, 0.25,
  0.75, 0.25, 0.5,  0.5,  1.0,
  1.0,  0.5,  0.5,  0.5,  0.5,
  0.5,  0.5,  0.5,  0.5,  0.75,
  0.25, 2.0
};

// 再生状態
int   index          = 0;
float ticksRemaining = 0;
boolean playing      = false;

// Karplus-Strong用バッファ
float[] ksBuffer;
int ksPointer;
int ksDelay;

// 音名表示用
float[] NOTE_FREQS  = {261.6, 349.2, 392.0, 440.0, 466.2, 523.3, 587.3};
String[] NOTE_NAMES = {"C4",  "F4",  "G4",  "A4",  "Bb4", "C5",  "D5" };

// =============================================
// setup()
// =============================================
void setup() {
  size(800, 400);

  println(Serial.list());
  myPort = new Serial(this, Serial.list()[3], 9600);
  myPort.bufferUntil('\n');

  minim  = new Minim(this);
  output = minim.getLineOut();

  background(0);
  println("シリアル待機中...");
}

// =============================================
// draw()
// =============================================
void draw() {
  background(0);
  drawWaveform(output);
}

// =============================================
// serialEvent()
// 1=1拍進める, 0=停止
// =============================================
void serialEvent(Serial p) {
  String line = p.readStringUntil('\n');
  if (line == null) return;

  line = trim(line);
  if (line.length() == 0) return;

  try {
    int v = Integer.parseInt(line);
    handleSignal(v);
  } catch (Exception e) {
    // 数字でない行は無視
  }
}

void handleSignal(int v) {
  if (v == 0) {
    stopPlaying();
  } else {
    if (!playing) startPlaying();
    onTick();
  }
}

void startPlaying() {
  playing        = true;
  index          = 0;
  ticksRemaining = 0;
  println("演奏開始");
}

void stopPlaying() {
  if (!playing) return;
  playing        = false;
  index          = 0;
  ticksRemaining = 0;
  println("演奏停止");
}

// =============================================
// onTick()
// 0.25拍ぶん進める
// =============================================
void onTick() {
  if (ticksRemaining > 0.25) {
    ticksRemaining -= 0.25;
    return;
  }
  playNote(noteArray[index], beatArray[index]);
  currentFrequency = noteArray[index];
  currentBeatLen   = beatArray[index];
  ticksRemaining   = beatArray[index];
  index++;
  if (index >= NOTE_COUNT) index = 0;
}

// =============================================
// Karplus-Strong 初期化
// [修正2] 係数を 1.1 → 1.6 に戻す
// =============================================
void initKarplusStrong(float frequency) {
  int Fs    = (int)output.sampleRate();
  ksDelay   = round(Fs / frequency * 1.6); // 修正：1.1 → 1.6
  ksBuffer  = new float[ksDelay];
  ksPointer = 0;
  for (int i = 0; i < ksDelay; i++) {
    ksBuffer[i] = random(-1.0, 1.0);
  }
}

float ksNextSample() {
  int next = (ksPointer + 1) % ksDelay;
  float filtered = 0.999 * (0.7 * ksBuffer[ksPointer] + 0.30 * ksBuffer[next]);
  ksBuffer[ksPointer] = filtered;
  ksPointer = next;
  return filtered;
}

// =============================================
// ADSR エンベロープ
// =============================================
float applyADSR(float t, float attack, float decay,
                float sustain, float release, float total) {
  if (t < attack) return t / attack;
  if (t < attack + decay) {
    float d = (t - attack) / decay;
    return lerp(1.0, sustain, d);
  }
  if (t < total - release) return sustain;
  float r = (t - (total - release)) / release;
  return sustain * (1.0 - r);
}

// =============================================
// createWaveform()
// [修正3] lowFreq = frequency / 1.6 を使った倍音付加に戻す
// [修正4] RELEASE_MS を考慮した動的 releaseRatio を復活
// =============================================
float[] createWaveform(float frequency, int samples, int durationMs) {
  initKarplusStrong(frequency);
  float[] buf = new float[samples];
  int Fs = (int)output.sampleRate();

  // 修正：ノート時間と余韻の比率を動的計算
  float noteRatio    = (float)durationMs / (durationMs + RELEASE_MS);
  float releaseRatio = 1.0 - noteRatio;

  // 修正：倍音の基準周波数を lowFreq = frequency/1.6 に戻す
  float lowFreq = frequency / 1.6;

  for (int i = 0; i < samples; i++) {
    float s = ksNextSample();

    float harmonics = 0.0;
    harmonics += 0.01  * sin(TWO_PI * lowFreq * 2 * i / Fs);
    harmonics += 0.005 * sin(TWO_PI * lowFreq * 3 * i / Fs);
    harmonics += 0.003 * sin(TWO_PI * lowFreq * 4 * i / Fs);
    harmonics += 0.001 * sin(TWO_PI * lowFreq * 5 * i / Fs);
    harmonics += 0.001 * sin(TWO_PI * lowFreq * 6 * i / Fs);

    if (i < 150) s += random(-0.08, 0.08);

    float t   = (float)i / samples;
    float env = applyADSR(t, 0.01, 0.20, 0.9, releaseRatio, 1.0); // 修正：動的 releaseRatio

    s += harmonics * env;

    buf[i] = s * env * 2.8;
    buf[i] = (float)Math.tanh(buf[i] * 1.3);
  }
  return buf;
}

// =============================================
// playNote()
// [修正5] RELEASE_MS を加えたサンプル長計算に戻す
// =============================================
void playNote(float frequency, float beatLen) {
  int Fs         = (int)output.sampleRate();
  int durationMs = (int)(30000.0 / BPM * beatLen);
  int samples    = (int)(Fs * (durationMs + RELEASE_MS) / 1000.0); // 修正：余韻分を加算

  float[] buf    = createWaveform(frequency, samples, durationMs);  // 修正：durationMs を渡す
  AudioSample sample = minim.createSample(buf, output.getFormat(), 512);
  sample.trigger();
  delay(durationMs);
  sample.close();
}

// =============================================
// drawWaveform()
// =============================================
void drawWaveform(AudioOutput output) {
  stroke(50);
  strokeWeight(1);
  line(0, height / 2, width, height / 2);

  stroke(0, 255, 128);
  strokeWeight(2);
  noFill();
  beginShape();
  for (int i = 0; i < output.bufferSize() - 1; i++) {
    float x = map(i, 0, output.bufferSize(), 0, width);
    float y = map(output.mix.get(i), -1, 1, 0, height);
    vertex(x, y);
  }
  endShape();

  fill(255);
  noStroke();
  textSize(16);
  text("Guitar - Serial Synchronized Playback", 20, 35);

  fill(playing ? color(0, 255, 128) : color(180));
  textSize(13);
  text(playing ? "● 演奏中" : "■ 停止中", 20, 60);

  if (currentFrequency > 0) {
    fill(0, 255, 128);
    text("音名: "     + freqToNoteName(currentFrequency), 20, 85);
    text("周波数: "   + nf(currentFrequency, 1, 1) + " Hz",  20, 105);
    text("拍長: "     + currentBeatLen + " 拍",              20, 125);
    text("再生位置: " + index + " / " + NOTE_COUNT,          20, 145);
  }
}

String freqToNoteName(float freq) {
  for (int i = 0; i < NOTE_FREQS.length; i++) {
    if (abs(freq - NOTE_FREQS[i]) < 1.0) return NOTE_NAMES[i];
  }
  return nf(freq, 1, 1) + " Hz";
}

void stop() {
  output.close();
  minim.stop();
  super.stop();
}
