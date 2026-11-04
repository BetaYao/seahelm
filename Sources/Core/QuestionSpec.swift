import Foundation

/// One AskUserQuestion question: its prompt plus the option labels.
struct QuestionSpec: Equatable {
    let prompt: String
    let options: [String]
    var flags = QuestionFlags()
}

/// How a question is answered in Claude's AskUserQuestion dialog, which is all
/// arrow keys and Return (a digit arrives as pasted text and is ignored):
/// - single-select: Return picks the row under the cursor and moves on;
/// - multi-select: Return *toggles* that row, and → leaves the question;
/// - an ask of several questions, or one multi-select question, ends on a
///   "Review your answers" page whose first row (Submit) needs one more Return.
struct QuestionFlags: Equatable {
    var multiSelect = false
    /// Answering this question lands on the review page rather than submitting.
    var reviewAfter = false
    /// Multi-select rows toggled on so far (0-based), for the buttons' ticks.
    var checked: Set<Int> = []
    /// Row the dialog's cursor was last moved to (0-based) — where arrows count
    /// from when the screen can't be read.
    var cursor = 0
    /// One AskUserQuestion call (its `tool_use_id`), shared by its questions.
    /// Asking the same question again is a new call, so its card is a new
    /// Telegram message rather than a duplicate of the last one.
    var askId = ""
}
