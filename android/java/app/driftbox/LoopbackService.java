package app.driftbox;

import android.media.midi.MidiDeviceService;
import android.media.midi.MidiReceiver;
import java.io.IOException;

/**
 * A MIDI device that sends back whatever it is sent, stamp and all: what the MIDI ports are tested
 * against without anything plugged in, as a loopback port is on Windows.
 */
public final class LoopbackService extends MidiDeviceService {
  @Override
  public MidiReceiver[] onGetInputPortReceivers() {
    return new MidiReceiver[] {
      new MidiReceiver() {
        @Override
        public void onSend(byte[] message, int offset, int count, long timestamp) throws IOException {
          MidiReceiver[] outputs = getOutputPortReceivers();
          if (outputs != null && outputs.length > 0) outputs[0].send(message, offset, count, timestamp);
        }
      }
    };
  }
}
