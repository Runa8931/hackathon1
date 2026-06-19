// 楽器側Arduino：メトロノームからBPMを受信し，拍が来たらProcessingへ拍信号を送る
// Serial1 … メトロノームArduinoからの受信（UART）
// Serial  … Processing（PC）への送信（USB）
// 楽譜はProcessing側が管理する．ここでは拍の合図だけを中継する．

char buf[16];                 // 受信文字列のバッファ
int  idx = 0;                 // バッファ書き込み位置

void setup() {
  Serial.begin(9600);         // Processingへの送信（USBシリアル）
  Serial1.begin(9600);        // メトロノームからの受信（UART）
}

void loop() {
  // メトロノームから1行分（数値＋改行）を受信するまで読み続ける
  while (Serial1.available() > 0) {
    char c = Serial1.read();

    if (c == '\n' || c == '\r') {
      if (idx > 0) {
        buf[idx] = '\0';      // 文字列を終端する
        int value = atoi(buf);// 受信したBPM値（0は停止）
        handleValue(value);
        idx = 0;              // 次の受信に備える
      }
    } else if (idx < (int)sizeof(buf) - 1) {
      buf[idx++] = c;         // 数字を1文字ずつ蓄える
    }
  }
}

// 受信した値に応じてProcessingへ合図を送る
void handleValue(int value) {
  if (value == 0) {
    Serial.println(0);   // つまみ最小（停止）：Processingへ停止を送る
  } else {
    Serial.println(1);   // 0以外は1拍ぶんのbeatとして「1」を送る
  }
}