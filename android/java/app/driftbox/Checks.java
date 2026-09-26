package app.driftbox;

/**
 * Whether the app has the checks {@code scripts/android-app.sh} runs on a phone: the harness
 * {@link Main} starts when named a test, and Driftbox Loopback. A release is built with this
 * class written again saying not, and without the loopback, which every other app would list.
 */
final class Checks {
  private Checks() {}

  static final boolean INCLUDED = true;
}
