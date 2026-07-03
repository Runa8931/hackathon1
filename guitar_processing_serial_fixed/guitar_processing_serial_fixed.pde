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
//
// システム全体における役割：
// ・子機Arduino（snow_density.ino）からUSBシリアル経由で 0/1 のみを受信する末端ノード。
// ・受信した「1」の回数だけを見て楽譜(noteArray/beatArray)を進める（BPMの実測値は使わない）。
// ・1音の再生時間（余韻を含むサンプル長）は、受信テンポとは無関係な固定値 BPM=160 から計算する。
//   つまり「いつ次の音に進むか」＝上流から届くtickの頻度、「1音をどれだけ鳴らすか」＝ローカル固定値、
//   という2つの独立したタイミング制御が同居している。
// ・音源はKarplus-Strong法（弦を弾いた音を模した遅延線フィルタ）で毎回その場で合成している。

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
boolean finished     = false; // 曲を最後まで弾き終わったフラグ（trueのとき拍信号が来ても再開しない）

// Karplus-Strong用バッファ
float[] ksBuffer;
int ksPointer;
int ksDelay;

// 音名表示用
float[] NOTE_FREQS  = {261.6, 349.2, 392.0, 440.0, 466.2, 523.3, 587.3};
String[] NOTE_NAMES = {"C4",  "F4",  "G4",  "A4",  "Bb4", "C5",  "D5" };

// =============================================
// setup()
// 起動時に1回だけ実行。シリアルポートとオーディオ出力を初期化する。
// =============================================
void setup() {
  size(800, 400);

  println(Serial.list());
  // Serial.list()[3] はPC環境（接続されているUSBデバイスの数や順序）に依存するため、
  // 実行環境が変わった場合はここのインデックスを実際のポート番号に合わせて変更する必要がある。
  myPort = new Serial(this, Serial.list()[3], 9600);
  myPort.bufferUntil('\n');  // 改行が来るまでバッファし、1行分そろってからserialEvent()を呼ぶ

  minim  = new Minim(this);
  output = minim.getLineOut();

  background(0);
  println("シリアル待機中...");
}

// =============================================
// draw()
// 画面を毎フレーム再描画するProcessing標準のループ関数。波形と状態表示を担当する。
// =============================================
void draw() {
  background(0);
  drawWaveform(output);
}

// =============================================
// serialEvent()
// 1行分のシリアル受信データが届くたびに呼ばれる。
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

// 受信値を処理する。0=停止、0以外=拍イベントとして扱う（値そのものは使わない）。
void handleSignal(int v) {
  if (v == 0) {
    stopPlaying();
    finished = false; // メトロノームが止まったらfinishedをリセット（次回演奏に備える）
  } else {
    if (finished) return; // 曲が終わっていたら拍信号が来ても無視する（ループさせない）
    if (!playing) startPlaying();
    onTick();
  }
}

void startPlaying() {
  playing        = true;
  index          = 0;         // 楽譜の先頭から演奏を始める
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
// 拍イベントを1回受け取るごとに、楽譜を0.25拍ぶん進める。
// 音符の長さ（beatArrayの値）が0.25より大きい場合は、必要な回数分tickを消費してから次の音に進む。
// =============================================
void onTick() {
  if (ticksRemaining > 0.25) {
    ticksRemaining -= 0.25;
    return;  // まだ今の音を鳴らし続ける拍数が残っているので、次の音には進まない
  }
  playNote(noteArray[index], beatArray[index]);
  currentFrequency = noteArray[index];
  currentBeatLen   = beatArray[index];
  ticksRemaining   = beatArray[index];
  index++;
  if (index >= NOTE_COUNT) {
    finished = true;  // 曲が終わったことを記録してから停止する（ループしない）
    stopPlaying();
  }
}

// =============================================
// Karplus-Strong 初期化
// [修正2] 係数を 1.1 → 1.6 に戻す
//
// Karplus-Strong法：ランダムノイズを詰めた遅延線（ksBuffer）を、少しずつ減衰させながら
// 繰り返し読み出すことで「弦を弾いた音」を模擬する物理モデル音源。
// 遅延線の長さ(ksDelay)が短いほど高い音、長いほど低い音になる＝これが音程を決める。
// =============================================
void initKarplusStrong(float frequency) {
  int Fs    = (int)output.sampleRate();
  ksDelay   = round(Fs / frequency * 1.6); // 修正：1.1 → 1.6　※この係数が音程・音色に直結する
  ksBuffer  = new float[ksDelay];
  ksPointer = 0;
  for (int i = 0; i < ksDelay; i++) {
    ksBuffer[i] = random(-1.0, 1.0);  // 弦を弾いた瞬間のランダムな振動として、白色ノイズで初期化する
  }
}

// 遅延線を1サンプル進める。隣り合う2点の平均を取りながら0.999倍することで、
// 高音域を少しずつ削りながら振幅を減衰させる＝弦の音が時間とともに丸く小さくなっていく効果を作る。
float ksNextSample() {
  int next = (ksPointer + 1) % ksDelay;
  float filtered = 0.999 * (0.7 * ksBuffer[ksPointer] + 0.30 * ksBuffer[next]);
  ksBuffer[ksPointer] = filtered;
  ksPointer = next;
  return filtered;
}

// =============================================
// ADSR エンベロープ
// 音量の時間変化（Attack立ち上がり／Decay減衰／Sustain維持／Release余韻）を作る関数。
// t は0.0〜1.0に正規化した経過時間で、返り値がその瞬間の音量倍率（0.0〜1.0）になる。
// =============================================
float applyADSR(float t, float attack, float decay,
                float sustain, float release, float total) {
  if (t < attack) return t / attack;                      // Attack：0から1まで直線的に立ち上がる
  if (t < attack + decay) {
    float d = (t - attack) / decay;
    return lerp(1.0, sustain, d);                          // Decay：1からsustainレベルまで下がる
  }
  if (t < total - release) return sustain;                 // Sustain：一定音量を維持する
  float r = (t - (total - release)) / release;
  return sustain * (1.0 - r);                               // Release：sustainレベルから0まで減衰する
}

// =============================================
// createWaveform()
// [修正3] lowFreq = frequency / 1.6 を使った倍音付加に戻す
// [修正4] RELEASE_MS を考慮した動的 releaseRatio を復活
//
// 1音分の波形サンプル列(buf)を生成する。Karplus-Strongの音（弦の基本音）に、
// 倍音成分・アタック時のノイズバースト・ADSRエンベロープ・ソフトクリップを重ねて
// 単なる遅延線の音よりギターらしい音色に近づけている。
// =============================================
float[] createWaveform(float frequency, int samples, int durationMs) {
  initKarplusStrong(frequency);
  float[] buf = new float[samples];
  int Fs = (int)output.sampleRate();

  // 修正：ノート時間と余韻の比率を動的計算
  // durationMs（発音時間）とRELEASE_MS（余韻）の比率から、ADSRのreleaseに使う割合を求める
  float noteRatio    = (float)durationMs / (durationMs + RELEASE_MS);
  float releaseRatio = 1.0 - noteRatio;

  // 修正：倍音の基準周波数を lowFreq = frequency/1.6 に戻す
  float lowFreq = frequency / 1.6;

  for (int i = 0; i < samples; i++) {
    float s = ksNextSample();  // Karplus-Strongによる弦の基本音

    // 2〜6倍音を弱く重ねて、単純な遅延線音より複雑な音色にする（倍音が強いほど硬い音になる）
    float harmonics = 0.0;
    harmonics += 0.01  * sin(TWO_PI * lowFreq * 2 * i / Fs);
    harmonics += 0.005 * sin(TWO_PI * lowFreq * 3 * i / Fs);
    harmonics += 0.003 * sin(TWO_PI * lowFreq * 4 * i / Fs);
    harmonics += 0.001 * sin(TWO_PI * lowFreq * 5 * i / Fs);
    harmonics += 0.001 * sin(TWO_PI * lowFreq * 6 * i / Fs);

    if (i < 150) s += random(-0.08, 0.08);  // 最初の150サンプルだけノイズを足し、弾いた瞬間のアタック感を出す

    float t   = (float)i / samples;
    float env = applyADSR(t, 0.01, 0.20, 0.9, releaseRatio, 1.0); // 修正：動的 releaseRatio

    s += harmonics * env;

    buf[i] = s * env * 2.8;
    buf[i] = (float)Math.tanh(buf[i] * 1.3);  // ソフトクリップ（tanh）で音割れを滑らかに抑える
  }
  return buf;
}

// =============================================
// playNote()
// [修正5] RELEASE_MS を加えたサンプル長計算に戻す
//
// 1音を実際に鳴らす。durationMsは受信テンポとは無関係の固定値BPM=160から計算しており、
// 「次の音にいつ進むか」（onTick側で制御）とは独立している点に注意。
// =============================================
void playNote(float frequency, float beatLen) {
  int Fs         = (int)output.sampleRate();
  int durationMs = (int)(30000.0 / BPM * beatLen);  // ローカル固定BPM=160を使い、音符の長さ[ms]を算出
  int samples    = (int)(Fs * (durationMs + RELEASE_MS) / 1000.0); // 修正：余韻分を加算

  float[] buf    = createWaveform(frequency, samples, durationMs);  // 修正：durationMs を渡す
  AudioSample sample = minim.createSample(buf, output.getFormat(), 512);
  sample.trigger();
  delay(durationMs);  // 音の発音時間ぶんだけ処理をブロックする（この間は次のtickを受信できても処理は後回しになる）
  sample.close();
}

// =============================================
// drawWaveform()
// 現在出力中の音声波形と、演奏状態（再生中/停止中・音名・周波数・拍長・再生位置）を
// 画面に描画する。音の合成には関与せず、あくまで確認用の可視化表示。
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

// 周波数から音名（C4, A4など）を逆引きする。一致するものがなければ周波数[Hz]をそのまま表示する
String freqToNoteName(float freq) {
  for (int i = 0; i < NOTE_FREQS.length; i++) {
    if (abs(freq - NOTE_FREQS[i]) < 1.0) return NOTE_NAMES[i];
  }
  return nf(freq, 1, 1) + " Hz";
}

// スケッチ終了時にオーディオリソースを解放する
void stop() {
  output.close();
  minim.stop();
  super.stop();
}
