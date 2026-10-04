package com.termux.view;

import android.content.Context;
import android.text.Editable;
import android.text.Selection;
import android.view.KeyEvent;
import android.view.View;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.InputMethodManager;

/**
 * An IME edits a document, not a stream of independent words. Keep Android's
 * editable, selection and composing spans authoritative, then synchronously
 * translate each completed edit into terminal keys. In particular, finishing a
 * composition does not forget text that the IME may subsequently recompose.
 */
abstract class TerminalInputConnection extends BaseInputConnection {
    private final View view;
    private String sent = "";
    private int cursor;
    private int batchDepth;
    private boolean closed;

    TerminalInputConnection(View view) { super(view, true); this.view = view; }

    protected abstract void writeText(CharSequence text);
    protected abstract void writeKey(int keyCode);

    @Override public boolean beginBatchEdit() { if (closed) return false; batchDepth++; return true; }

    @Override public boolean endBatchEdit() {
        if (closed) return false;
        if (batchDepth > 0) batchDepth--;
        if (batchDepth == 0) synchronize();
        return batchDepth > 0;
    }

    @Override public boolean setComposingText(CharSequence text, int position) {
        return !closed && super.setComposingText(text, position);
    }

    @Override public boolean commitText(CharSequence text, int position) {
        return !closed && super.commitText(text, position);
    }

    @Override public boolean finishComposingText() { return !closed && super.finishComposingText(); }

    @Override public boolean setComposingRegion(int start, int end) {
        return !closed && super.setComposingRegion(start, end);
    }

    @Override public boolean setSelection(int start, int end) {
        if (closed) return false;
        boolean result = super.setSelection(start, end);
        if (batchDepth == 0) synchronize();
        return result;
    }

    @Override public boolean deleteSurroundingText(int before, int after) {
        return deleteAround(before, after, false);
    }

    @Override public boolean deleteSurroundingTextInCodePoints(int before, int after) {
        return deleteAround(before, after, true);
    }

    private boolean deleteAround(int before, int after, boolean codePoints) {
        if (closed || before < 0 || after < 0) return false;
        Editable text = getEditable();
        int a = Math.min(Selection.getSelectionStart(text), Selection.getSelectionEnd(text));
        int b = Math.max(Selection.getSelectionStart(text), Selection.getSelectionEnd(text));
        if (a < 0) return false;
        int ca = getComposingSpanStart(text), cb = getComposingSpanEnd(text);
        if (ca >= 0 && cb >= 0) { a = Math.min(a, ca); b = Math.max(b, cb); }
        int knownBefore = codePoints ? Character.codePointCount(text, 0, a) : a;
        int knownAfter = codePoints ? Character.codePointCount(text, b, text.length()) : text.length() - b;
        // The terminal can contain input from before this connection. Do not
        // swallow backspace/delete merely because that text is outside our mirror.
        int extraBefore = Math.max(0, before - knownBefore);
        int extraAfter = Math.max(0, after - knownAfter);
        boolean result = codePoints ? super.deleteSurroundingTextInCodePoints(before, after)
            : super.deleteSurroundingText(before, after);
        if (extraBefore > 0 || extraAfter > 0) {
            synchronize();
            if (extraBefore > 0) {
                move(sent, cursor, 0);
                for (int i = 0; i < extraBefore; i++) writeKey(KeyEvent.KEYCODE_DEL);
                move(sent, 0, cursor);
            }
            if (extraAfter > 0) {
                move(sent, cursor, sent.length());
                for (int i = 0; i < extraAfter; i++) writeKey(KeyEvent.KEYCODE_FORWARD_DEL);
                move(sent, sent.length(), cursor);
            }
        }
        return result;
    }

    @Override public boolean sendKeyEvent(KeyEvent event) {
        if (closed) return false;
        if (event.getAction() != KeyEvent.ACTION_DOWN) return view.onKeyUp(event.getKeyCode(), event);
        int key = event.getKeyCode();
        Editable text = getEditable();
        if (!event.isCtrlPressed() && !event.isAltPressed()) {
            int a = Math.min(Selection.getSelectionStart(text), Selection.getSelectionEnd(text));
            int b = Math.max(Selection.getSelectionStart(text), Selection.getSelectionEnd(text));
            if (key == KeyEvent.KEYCODE_DEL || key == KeyEvent.KEYCODE_FORWARD_DEL) {
                if (a == b) {
                    if (key == KeyEvent.KEYCODE_DEL && a > 0) a = Character.offsetByCodePoints(text, a, -1);
                    else if (key == KeyEvent.KEYCODE_FORWARD_DEL && b < text.length()) b = Character.offsetByCodePoints(text, b, 1);
                }
                if (a != b) { text.delete(a, b); Selection.setSelection(text, a); synchronize(); }
                else writeKey(key);
                return true;
            }
            if (key == KeyEvent.KEYCODE_DPAD_LEFT || key == KeyEvent.KEYCODE_DPAD_RIGHT) {
                finishComposingText();
                int position = Selection.getSelectionEnd(text);
                int direction = key == KeyEvent.KEYCODE_DPAD_LEFT ? -1 : 1;
                if ((direction < 0 && position > 0) || (direction > 0 && position < text.length())) {
                    return setSelection(Character.offsetByCodePoints(text, position, direction),
                        Character.offsetByCodePoints(text, position, direction));
                }
            } else if (event.getUnicodeChar() >= 32) {
                finishComposingText();
                return commitText(new String(Character.toChars(event.getUnicodeChar())), 1);
            }
        }
        // Enter, history navigation, shortcuts, etc. may change arbitrary remote
        // text. A subsequent composition must not edit a stale local document.
        invalidateContext();
        return view.onKeyDown(key, event);
    }

    /** Called before hardware/accessory input which bypasses the IME document. */
    boolean invalidateContext() {
        boolean hadText = getEditable().length() != 0;
        if (!closed) synchronize();
        clearContext();
        notifySelection();
        return hadText;
    }

    private void clearContext() {
        Editable text = getEditable();
        text.clear();
        removeComposingSpans(text);
        Selection.setSelection(text, 0);
        sent = "";
        cursor = 0;
    }

    @Override public void closeConnection() {
        if (closed) return;
        super.closeConnection();
        closed = true;
        clearContext();
    }

    private void synchronize() {
        if (closed) return;
        Editable editable = getEditable();
        String next = editable.toString();
        int nextCursor = Selection.getSelectionEnd(editable);
        if (nextCursor < 0) return;
        int prefix = 0;
        while (prefix < sent.length() && prefix < next.length()) {
            int a = sent.codePointAt(prefix), b = next.codePointAt(prefix);
            if (a != b) break;
            prefix += Character.charCount(a);
        }
        int oldEnd = sent.length(), newEnd = next.length();
        while (oldEnd > prefix && newEnd > prefix) {
            int a = sent.codePointBefore(oldEnd), b = next.codePointBefore(newEnd);
            if (a != b) break;
            oldEnd -= Character.charCount(a);
            newEnd -= Character.charCount(b);
        }
        if (oldEnd != prefix || newEnd != prefix) {
            move(sent, cursor, oldEnd);
            int deletes = sent.codePointCount(prefix, oldEnd);
            for (int i = 0; i < deletes; i++) writeKey(KeyEvent.KEYCODE_DEL);
            String inserted = next.substring(prefix, newEnd);
            if (!inserted.isEmpty()) writeText(inserted);
            cursor = newEnd;
            // A control character can submit a command/change editor state. Do
            // not offer previous command text to later IME edits.
            if (inserted.codePoints().anyMatch(c -> c < 32 || c == 127)) {
                clearContext();
                notifySelection();
                return;
            }
        }
        move(next, cursor, nextCursor);
        sent = next;
        cursor = nextCursor;
        notifySelection();
    }

    private void move(String text, int from, int to) {
        int count = text.codePointCount(Math.min(from, to), Math.max(from, to));
        int key = to < from ? KeyEvent.KEYCODE_DPAD_LEFT : KeyEvent.KEYCODE_DPAD_RIGHT;
        for (int i = 0; i < count; i++) writeKey(key);
    }

    private void notifySelection() {
        InputMethodManager manager = (InputMethodManager) view.getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
        if (manager == null) return;
        Editable text = getEditable();
        manager.updateSelection(view, Selection.getSelectionStart(text), Selection.getSelectionEnd(text),
            getComposingSpanStart(text), getComposingSpanEnd(text));
    }
}
