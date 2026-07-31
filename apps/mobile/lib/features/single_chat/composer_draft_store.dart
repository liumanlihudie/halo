/// Keeps what the user was typing when they left a chat.
///
/// The composer's text lived only in the page's controller, so any navigation
/// — checking another chat, answering a call — threw the draft away. Every
/// messenger keeps drafts; this one keeps them per conversation for the life
/// of the process, which is the window in which "I stepped away for a second"
/// happens. Clearing on send keeps a sent message from reappearing as a ghost
/// draft.
final class ComposerDraftStore {
  ComposerDraftStore._();

  static final ComposerDraftStore instance = ComposerDraftStore._();

  final Map<String, String> _drafts = {};

  String read(String conversationId) => _drafts[conversationId] ?? '';

  void write(String conversationId, String text) {
    if (text.isEmpty) {
      _drafts.remove(conversationId);
    } else {
      _drafts[conversationId] = text;
    }
  }

  void clear(String conversationId) => _drafts.remove(conversationId);
}
