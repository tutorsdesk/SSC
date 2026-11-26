/// Splits an MCQ whose text starts with a shared stimulus block
/// ("উদ্দীপক: …", then a blank line, then the question) so the stimulus can
/// print without a question number and the question keeps its own number.
({String? stimulus, String body}) splitMcqStimulus(String text) {
  const label = 'উদ্দীপক: ';
  if (!text.startsWith(label)) return (stimulus: null, body: text);
  final cut = text.indexOf('\n\n');
  if (cut <= label.length) return (stimulus: null, body: text);
  return (
    stimulus: text.substring(0, cut).trimRight(),
    body: text.substring(cut + 2).trimLeft(),
  );
}
