package com.termux.terminal;

/**
 * Stub: this client renders REMOTE sessions fed over a WebSocket, so it never
 * spawns a local subprocess. The original JNI native methods (and the
 * libtermux.so they need) are replaced with harmless no-ops; the remote path in
 * {@link TerminalSession} never calls them.
 */
final class JNI {
    static int createSubprocess(String cmd, String cwd, String[] args, String[] env, int[] processId, int rows, int columns, int cellWidth, int cellHeight) {
        processId[0] = -1;
        return -1;
    }
    static void setPtyWindowSize(int fd, int rows, int cols, int cellWidth, int cellHeight) {}
    static int waitFor(int processId) { return 0; }
    static void close(int fileDescriptor) {}
}
