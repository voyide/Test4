import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => TestEngine(),
      child: const ProTestApp(),
    ),
  );
}

class ProTestApp extends StatelessWidget {
  const ProTestApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pro Test App',
      theme: ThemeData(
        primarySwatch: Colors.blueGrey,
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
      ),
      home: const DashboardScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ============================================================================
// MODELS
// ============================================================================

class Question {
  final String id;
  final String text;
  final List<String> options;
  final List<int> correctIndices;
  final String explanation;

  Question({
    required this.id,
    required this.text,
    required this.options,
    required this.correctIndices,
    required this.explanation,
  });

  factory Question.fromJson(Map<String, dynamic> json) {
    return Question(
      id: json['id']?.toString() ?? UniqueKey().toString(),
      text: json['text'] ?? '',
      options: List<String>.from(json['options'] ?? []),
      correctIndices: List<int>.from(json['correct_indices'] ?? []),
      explanation: json['explanation'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'options': options,
        'correct_indices': correctIndices,
        'explanation': explanation,
      };
}

class Test {
  final String id;
  final String title;
  final String category;
  final int durationMinutes;
  final List<Question> questions;

  Test({
    required this.id,
    required this.title,
    required this.category,
    required this.durationMinutes,
    required this.questions,
  });

  factory Test.fromJson(Map<String, dynamic> json) {
    var qList = json['questions'] as List? ?? [];
    return Test(
      id: json['test_id']?.toString() ?? UniqueKey().toString(),
      title: json['title'] ?? 'Untitled Test',
      category: json['category'] ?? 'General',
      durationMinutes: json['duration_minutes'] ?? 60,
      questions: qList.map((q) => Question.fromJson(q)).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'test_id': id,
        'title': title,
        'category': category,
        'duration_minutes': durationMinutes,
        'questions': questions.map((q) => q.toJson()).toList(),
      };
}

enum QuestionStatus { unvisited, answered, marked, markedAndAnswered, visited }

class TestSession {
  final Test test;
  Map<String, List<int>> userAnswers = {};
  Map<String, QuestionStatus> statuses = {};
  DateTime startTime = DateTime.now();
  DateTime? endTime;

  TestSession(this.test) {
    for (var q in test.questions) {
      statuses[q.id] = QuestionStatus.unvisited;
    }
    if (test.questions.isNotEmpty) {
      statuses[test.questions.first.id] = QuestionStatus.visited;
    }
  }
}

// ============================================================================
// STATE MANAGEMENT
// ============================================================================

class TestEngine extends ChangeNotifier {
  List<Test> availableTests = [];
  TestSession? currentSession;

  TestEngine() {
    _loadTests();
  }

  Future<void> _loadTests() async {
    final prefs = await SharedPreferences.getInstance();
    final testsJson = prefs.getString('saved_tests');
    if (testsJson != null) {
      try {
        final decoded = jsonDecode(testsJson) as List;
        availableTests = decoded.map((e) => Test.fromJson(e)).toList();
        notifyListeners();
      } catch (e) {
        debugPrint("Load failed: $e");
      }
    }
  }

  Future<void> _saveTests() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(availableTests.map((e) => e.toJson()).toList());
    await prefs.setString('saved_tests', encoded);
  }

  Future<void> importTestFromFile(BuildContext context) async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt'],
      );
      if (result != null && result.files.single.path != null) {
        File file = File(result.files.single.path!);
        String contents = await file.readAsString();
        importTestFromString(contents, context);
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error reading file')));
    }
  }

  void importTestFromString(String jsonString, BuildContext context) async {
    try {
      final jsonMap = jsonDecode(jsonString);
      Test newTest = Test.fromJson(jsonMap);
      availableTests.removeWhere((t) => t.id == newTest.id);
      availableTests.add(newTest);
      await _saveTests();
      notifyListeners();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Test Imported Successfully')));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Import Failed: Invalid JSON format')));
    }
  }

  void startTest(Test test) {
    currentSession = TestSession(test);
    notifyListeners();
  }

  void updateAnswer(String questionId, int optionIndex, bool isMulti) {
    if (currentSession == null) return;
    if (isMulti) {
      var current = currentSession!.userAnswers[questionId] ?? [];
      if (current.contains(optionIndex)) {
        current.remove(optionIndex);
      } else {
        current.add(optionIndex);
      }
      if (current.isEmpty) {
        currentSession!.userAnswers.remove(questionId);
      } else {
        currentSession!.userAnswers[questionId] = current;
      }
    } else {
      currentSession!.userAnswers[questionId] = [optionIndex];
    }
    notifyListeners();
  }

  void setStatus(String questionId, QuestionStatus status) {
    if (currentSession == null) return;
    currentSession!.statuses[questionId] = status;
    notifyListeners();
  }

  void clearResponse(String questionId) {
    if (currentSession == null) return;
    currentSession!.userAnswers.remove(questionId);
    notifyListeners();
  }

  void endTest() {
    if (currentSession != null) {
      currentSession!.endTime = DateTime.now();
      notifyListeners();
    }
  }
  
  void deleteTest(String testId) async {
    availableTests.removeWhere((t) => t.id == testId);
    await _saveTests();
    notifyListeners();
  }
}

// ============================================================================
// UI SCREENS
// ============================================================================

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({Key? key}) : super(key: key);

  void _showImportDialog(BuildContext context) {
    final TextEditingController ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Import Test"),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton.icon(
                icon: const Icon(Icons.file_upload),
                label: const Text("Pick JSON File"),
                onPressed: () {
                  Navigator.pop(context);
                  Provider.of<TestEngine>(context, listen: false)
                      .importTestFromFile(context);
                },
              ),
              const SizedBox(height: 16),
              const Text("OR Paste JSON String:"),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                maxLines: 5,
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              if (ctrl.text.trim().isNotEmpty) {
                Provider.of<TestEngine>(context, listen: false)
                    .importTestFromString(ctrl.text, context);
              }
            },
            child: const Text("Import"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final engine = context.watch<TestEngine>();
    
    Map<String, List<Test>> grouped = {};
    for (var t in engine.availableTests) {
      grouped.putIfAbsent(t.category, () => []).add(t);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Test Explorer')),
      body: engine.availableTests.isEmpty
          ? const Center(child: Text("No tests imported yet. Import a JSON file."))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: grouped.entries.map((entry) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(entry.key,
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold)),
                    ),
                    ...entry.value.map((test) => Card(
                          child: ListTile(
                            title: Text(test.title),
                            subtitle: Text("${test.questions.length} questions • ${test.durationMinutes} mins"),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () => engine.deleteTest(test.id),
                            ),
                            onTap: () {
                              engine.startTest(test);
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const ActiveTestScreen()),
                              );
                            },
                          ),
                        )),
                    const SizedBox(height: 16),
                  ],
                );
              }).toList(),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showImportDialog(context),
        icon: const Icon(Icons.add),
        label: const Text("Import Test"),
      ),
    );
  }
}

class ActiveTestScreen extends StatefulWidget {
  const ActiveTestScreen({Key? key}) : super(key: key);

  @override
  State<ActiveTestScreen> createState() => _ActiveTestScreenState();
}

class _ActiveTestScreenState extends State<ActiveTestScreen> {
  int currentIndex = 0;
  Timer? _timer;
  int _remainingSeconds = 0;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    final session = Provider.of<TestEngine>(context, listen: false).currentSession!;
    _remainingSeconds = session.test.durationMinutes * 60;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remainingSeconds > 0) {
        setState(() { _remainingSeconds--; });
      } else {
        _submitTest();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _submitTest() {
    _timer?.cancel();
    final engine = Provider.of<TestEngine>(context, listen: false);
    engine.endTest();
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => const ResultScreen()));
  }

  void _goToQuestion(int index, TestEngine engine) {
    setState(() {
      currentIndex = index;
      var qId = engine.currentSession!.test.questions[index].id;
      if (engine.currentSession!.statuses[qId] == QuestionStatus.unvisited) {
        engine.setStatus(qId, QuestionStatus.visited);
      }
    });
  }

  void _handleNext(TestEngine engine, QuestionStatus statusToSet) {
    var qId = engine.currentSession!.test.questions[currentIndex].id;
    bool isAnswered = engine.currentSession!.userAnswers.containsKey(qId) &&
                      engine.currentSession!.userAnswers[qId]!.isNotEmpty;
    
    QuestionStatus finalStatus = statusToSet;
    if (statusToSet == QuestionStatus.answered && !isAnswered) {
      finalStatus = QuestionStatus.visited;
    } else if (statusToSet == QuestionStatus.marked && isAnswered) {
      finalStatus = QuestionStatus.markedAndAnswered;
    }
    
    engine.setStatus(qId, finalStatus);
    
    if (currentIndex < engine.currentSession!.test.questions.length - 1) {
      _goToQuestion(currentIndex + 1, engine);
    } else {
      _scaffoldKey.currentState?.openEndDrawer();
    }
  }

  String _formatTime(int seconds) {
    int h = seconds ~/ 3600;
    int m = (seconds % 3600) ~/ 60;
    int s = seconds % 60;
    return h > 0 
        ? '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
        : '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Color _getStatusColor(QuestionStatus status) {
    switch (status) {
      case QuestionStatus.unvisited: return Colors.grey[300]!;
      case QuestionStatus.visited: return Colors.red;
      case QuestionStatus.answered: return Colors.green;
      case QuestionStatus.marked: return Colors.purple;
      case QuestionStatus.markedAndAnswered: return Colors.deepPurple;
    }
  }

  @override
  Widget build(BuildContext context) {
    final engine = context.watch<TestEngine>();
    final session = engine.currentSession;
    if (session == null) return const Scaffold();

    final question = session.test.questions[currentIndex];
    final userAns = session.userAnswers[question.id] ?? [];
    final bool isMulti = question.correctIndices.length > 1;

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(session.test.title),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _formatTime(_remainingSeconds),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.amberAccent),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.grid_view),
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
          )
        ],
      ),
      endDrawer: Drawer(
        child: SafeArea(
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text("Question Palette", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: session.test.questions.length,
                  itemBuilder: (context, index) {
                    var qStatus = session.statuses[session.test.questions[index].id]!;
                    return InkWell(
                      onTap: () {
                        Navigator.pop(context);
                        _goToQuestion(index, engine);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: _getStatusColor(qStatus),
                          shape: BoxShape.circle,
                          border: currentIndex == index ? Border.all(color: Colors.black, width: 3) : null,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          "${index + 1}",
                          style: TextStyle(
                            color: qStatus == QuestionStatus.unvisited ? Colors.black : Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                    onPressed: () {
                      Navigator.pop(context);
                      _submitTest();
                    },
                    child: const Text("Submit Test"),
                  ),
                ),
              )
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Question ${currentIndex + 1}", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  MarkdownBody(data: question.text, selectable: true),
                  const SizedBox(height: 24),
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: question.options.length,
                    itemBuilder: (context, optIdx) {
                      if (isMulti) {
                        return CheckboxListTile(
                          title: MarkdownBody(data: question.options[optIdx]),
                          value: userAns.contains(optIdx),
                          onChanged: (val) => engine.updateAnswer(question.id, optIdx, true),
                        );
                      } else {
                        return RadioListTile<int>(
                          value: optIdx,
                          groupValue: userAns.isNotEmpty ? userAns.first : null,
                          title: MarkdownBody(data: question.options[optIdx]),
                          onChanged: (val) {
                            if (val != null) engine.updateAnswer(question.id, val, false);
                          },
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            color: Colors.white,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: () => engine.clearResponse(question.id),
                  child: const Text("Clear Response"),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.purple),
                  onPressed: () => _handleNext(engine, QuestionStatus.marked),
                  child: const Text("Mark for Review & Next"),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                  onPressed: () => _handleNext(engine, QuestionStatus.answered),
                  child: const Text("Save & Next"),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }
}

class ResultScreen extends StatelessWidget {
  const ResultScreen({Key? key}) : super(key: key);

  bool _checkIsCorrect(Question q, List<int> userAns) {
    if (q.correctIndices.length != userAns.length) return false;
    var sortedCorrect = List<int>.from(q.correctIndices)..sort();
    var sortedUser = List<int>.from(userAns)..sort();
    for (int i = 0; i < sortedCorrect.length; i++) {
      if (sortedCorrect[i] != sortedUser[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final session = Provider.of<TestEngine>(context, listen: false).currentSession;
    if (session == null) return const Scaffold();

    int total = session.test.questions.length;
    int correct = 0;
    int incorrect = 0;
    int unanswered = 0;

    for (var q in session.test.questions) {
      var userAns = session.userAnswers[q.id];
      if (userAns == null || userAns.isEmpty) {
        unanswered++;
      } else {
        if (_checkIsCorrect(q, userAns)) {
          correct++;
        } else {
          incorrect++;
        }
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Test Results'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildStat("Score", "$correct / $total", Colors.blue),
                _buildStat("Accuracy", total - unanswered > 0 ? "${((correct / (total - unanswered)) * 100).toStringAsFixed(1)}%" : "0%", Colors.green),
                _buildStat("Skipped", "$unanswered", Colors.grey),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1),
          Expanded(
            child: ListView.builder(
              itemCount: session.test.questions.length,
              itemBuilder: (context, index) {
                var q = session.test.questions[index];
                var userAns = session.userAnswers[q.id] ?? [];
                bool isAttempted = userAns.isNotEmpty;
                bool isCorrect = isAttempted && _checkIsCorrect(q, userAns);

                Color headerColor = isAttempted 
                    ? (isCorrect ? Colors.green[100]! : Colors.red[100]!)
                    : Colors.grey[200]!;
                String statusText = isAttempted 
                    ? (isCorrect ? "Correct" : "Incorrect") 
                    : "Not Attempted";

                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Theme(
                    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      collapsedBackgroundColor: headerColor,
                      backgroundColor: headerColor,
                      title: Text("Question ${index + 1} - $statusText", 
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                      children: [
                        Container(
                          color: Colors.white,
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              MarkdownBody(data: q.text),
                              const SizedBox(height: 16),
                              const Text("Options:", style: TextStyle(fontWeight: FontWeight.bold)),
                              ...q.options.asMap().entries.map((opt) {
                                bool isUserChoice = userAns.contains(opt.key);
                                bool isCorrectChoice = q.correctIndices.contains(opt.key);
                                return ListTile(
                                  dense: true,
                                  leading: Icon(
                                    isCorrectChoice ? Icons.check_circle : (isUserChoice ? Icons.cancel : Icons.circle_outlined),
                                    color: isCorrectChoice ? Colors.green : (isUserChoice ? Colors.red : Colors.grey),
                                  ),
                                  title: MarkdownBody(data: opt.value),
                                );
                              }),
                              const Divider(),
                              const Text("Explanation:", style: TextStyle(fontWeight: FontWeight.bold)),
                              const SizedBox(height: 8),
                              MarkdownBody(data: q.explanation.isNotEmpty ? q.explanation : "No explanation provided."),
                            ],
                          ),
                        )
                      ],
                    ),
                  ),
                );
              },
            ),
          )
        ],
      ),
    );
  }

  Widget _buildStat(String label, String value, Color color) {
    return Column(
      children: [
        Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: const TextStyle(fontSize: 14, color: Colors.black54)),
      ],
    );
  }
}
