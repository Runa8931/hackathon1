// =============================================
// Processing プログラム（ギター担当）
// Minimライブラリ使用・Karplus-Strong実装版
// スペースキー：再生/停止　Rキー：先頭に戻る
// =============================================

import processing.serial.*;
import ddf.minim.*;
import ddf.minim.ugens.*;

Serial myPort;
Minim minim;
AudioOutput output;

float currentFrequency = 0;
float currentBeatLen   = 1.0;

// BPM（メトロノームArduinoと合わせる）
final int BPM = 160;

// 余韻時間（ms）playNoteとcreateWaveformで共通して使用
final int RELEASE_MS = 800; //なり終わりの余白を延長

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

// Karplus-Strong用バッファ
float[] ksBuffer;
int ksPointer;
int ksDelay;

// テスト再生用
boolean testPlaying = false;
int testNoteIndex   = 0;
long nextNoteTime   = 0;

// 音名表示用
float[] NOTE_FREQS  = {261.6, 349.2, 392.0, 440.0, 466.2, 523.3, 587.3};
String[] NOTE_NAMES = {"C4",  "F4",  "G4",  "A4",  "Bb4", "C5",  "D5" };

// =============================================
// setup()
// =============================================
void setup() {
  size(800, 400);

  // シリアル通信の初期化（"COM3"は環境に合わせて変更）
  // テストのみであればコメントアウト可
  // myPort = new Serial(this, "COM3", 9600);
  // myPort.bufferUntil('\n');

  minim  = new Minim(this);
  output = minim.getLineOut();

  background(0);
  println("スペースキー：再生/停止　Rキー：先頭に戻る");
}

// =============================================
// draw()
// =============================================
void draw() {
  background(0);
  drawWaveform(output);

  if (testPlaying && millis() >= nextNoteTime) {
    float freq = noteArray[testNoteIndex];
    float beat = beatArray[testNoteIndex];
    currentFrequency = freq;
    currentBeatLen   = beat;

    playNote(freq, beat);

    testNoteIndex++;
    if (testNoteIndex >= NOTE_COUNT) {
      testNoteIndex = 0;
    }

    nextNoteTime = millis() + (long)(60000.0 / BPM * beat);
  }
}

// =============================================
// keyPressed()
// =============================================
void keyPressed() {
  if (key == ' ') {
    testPlaying = !testPlaying;
    if (testPlaying) {
      nextNoteTime = millis();
      println("テスト再生 開始");
    } else {
      println("テスト再生 停止");
    }
  }
  if (key == 'r' || key == 'R') {
    testNoteIndex = 0;
    nextNoteTime  = millis();
    println("先頭に戻りました");
  }
}

// =============================================
// serialEvent()
// =============================================
void serialEvent(Serial port) {
  float[] data = receiveNoteData(port);
  if (data != null) {
    testPlaying      = false;
    currentFrequency = data[0];
    currentBeatLen   = data[1];
    playNote(currentFrequency, currentBeatLen);
  }
}

// =============================================
// receiveNoteData()
// 引数  : port（Serialポート）
// 戻り値: float[]（[周波数, 拍長]、失敗時はnull）
// =============================================
float[] receiveNoteData(Serial port) {
  try {
    String raw = port.readStringUntil('\n');
    if (raw != null) {
      String[] parts = trim(raw).split(",");
      if (parts.length == 2) {
        return new float[]{float(parts[0]), float(parts[1])};
      }
    }
  } catch (Exception e) {
    println("受信エラー: " + e.getMessage());
  }
  return null;
}

// =============================================
// initKarplusStrong()
// 引数  : frequency（Hz）
// 戻り値: void
// =============================================
void initKarplusStrong(float frequency) {
  int Fs    = (int)output.sampleRate();
  ksDelay   = round(Fs / frequency * 1.6);
  ksBuffer  = new float[ksDelay];
  ksPointer = 0;

  for (int i = 0; i < ksDelay; i++) {
    ksBuffer[i] = random(-1.0, 1.0);
  }
}

// =============================================
// ksNextSample()
// 引数  : なし
// 戻り値: float（次の1サンプル値）
// =============================================
float ksNextSample() {
  int next = (ksPointer + 1) % ksDelay;

  float filtered =
    0.999 * (0.7  * ksBuffer[ksPointer]//0.999で弦の振動を伸ばす
           + 0.30 * ksBuffer[next]);

  ksBuffer[ksPointer] = filtered;
  ksPointer = next;

  return filtered;
}

// =============================================
// applyADSR()
// 引数  : t, attack, decay, sustain, release, total
// 戻り値: float（エンベロープの音量値）
// =============================================
float applyADSR(float t, float attack, float decay,
                float sustain, float release, float total) {
  if (t < attack) {
    return t / attack;
  }
  if (t < attack + decay) {
    float d = (t - attack) / decay;
    return lerp(1.0, sustain, d);
  }
  if (t < total - release) {
    return sustain;
  }
  float r = (t - (total - release)) / release;
  return sustain * (1.0 - r);
}

// =============================================
// createWaveform()
// 引数  : frequency（Hz）, samples（サンプル数）, durationMs（発音時間ms）
// 戻り値: float[]
// =============================================
float[] createWaveform(float frequency, int samples, int durationMs) {
  initKarplusStrong(frequency);

  float[] buf = new float[samples];
  int Fs = (int)output.sampleRate();

  float noteRatio    = (float)durationMs / (durationMs + RELEASE_MS);
  float releaseRatio = 1.0 - noteRatio;

  for (int i = 0; i < samples; i++) {
    float s = ksNextSample();

float lowFreq = frequency / 1.6; // ksDelayの係数と合わせる

float harmonics = 0.0;
harmonics += 0.01  * sin(TWO_PI * lowFreq * 2 * i / Fs);
harmonics += 0.005 * sin(TWO_PI * lowFreq * 3 * i / Fs);
harmonics += 0.003 * sin(TWO_PI * lowFreq * 4 * i / Fs);
harmonics += 0.001 * sin(TWO_PI * lowFreq * 5 * i / Fs);
harmonics += 0.001 * sin(TWO_PI * lowFreq * 6 * i / Fs);

    if (i < 150) {
      s += random(-0.08, 0.08);
    }

    float t   = (float)i / samples;
    float env = applyADSR(t, 0.01, 0.20, 0.9, releaseRatio, 1.0);

    s += harmonics * env;

    buf[i] = s * env * 2.8;
    buf[i] = (float)Math.tanh(buf[i] * 1.3);
  }

  return buf;
}

// =============================================
// playNote()
// 引数  : frequency（Hz）, beatLen（拍の長さ）
// 戻り値: void
// =============================================
void playNote(float frequency, float beatLen) {
  int Fs         = (int)output.sampleRate();
  int durationMs = (int)(30000.0 / BPM * beatLen ); //音を早めに切っていた係数 0.8 を外し，拍の長さいっぱい鳴らすようにした．
  int samples    = (int)(Fs * (durationMs + RELEASE_MS) / 1000.0);

  float[] buf = createWaveform(frequency, samples, durationMs);

  AudioSample sample = minim.createSample(buf, output.getFormat(), 512);
  sample.trigger();
  delay(durationMs);
  sample.close();
}

// =============================================
// drawWaveform()
// 引数  : output（AudioOutput）
// 戻り値: void
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
  text("Guitar - Synchronized Playback", 20, 35);
  textSize(12);
  fill(150);
  text("スペース：再生/停止　R：先頭に戻る", 20, 58);

  if (testPlaying) {
    fill(0, 255, 128);
    text("● TEST PLAYING", 20, 80);
  }

  if (currentFrequency > 0) {
    textSize(13);
    fill(0, 255, 128);
    text("音名: "     + freqToNoteName(currentFrequency), 20, 105);
    text("周波数: "   + nf(currentFrequency, 1, 1) + " Hz", 20, 125);
    text("拍長: "     + currentBeatLen + " 拍", 20, 145);
    text("再生位置: " + testNoteIndex + " / " + NOTE_COUNT, 20, 165);
  }
}

// =============================================
// freqToNoteName()（表示用ヘルパー）
// =============================================
String freqToNoteName(float freq) {
  for (int i = 0; i < NOTE_FREQS.length; i++) {
    if (abs(freq - NOTE_FREQS[i]) < 1.0) return NOTE_NAMES[i];
  }
  return nf(freq, 1, 1) + " Hz";
}

// =============================================
// stop()
// =============================================
void stop() {
  output.close();
  minim.stop();
  super.stop();
}
