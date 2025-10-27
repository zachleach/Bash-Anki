# Bash Anki

A terminal-based spaced repetition system for people who live in the command line. Review flashcards without leaving Vim, sync via CSV exports, and keep your learning workflow exactly where you take your notes.

## Why I Built This

My learning process is pretty consistent:

1. **Scope the subject** — figure out what I want to understand
2. **45-60 minute session** — focused study time
3. **5-6 high-quality Q/A pairs** — distill the core concepts into flashcards
4. **Add to Anki** — store them for spaced repetition
5. **Morning review** — go through all due cards when I sit down at my desk

This worked great until I hit two problems:

### Problem 1: Minor Friction with the GUI
I take all my notes in Vim in the terminal. Copy-pasting Q/A pairs from my text files into Anki's GUI was workable, but added a small bit of friction to my workflow. It felt like unnecessary overhead when I could just review in the same environment where I write.

### Problem 2: Work Laptop Restrictions
I can't install Anki on my work machine, making it hard to review material I need professionally.

### My Custom Review Schedule

I use a non-standard Anki schedule: **1 3 7 9999**

- **Get it wrong**: See it again tomorrow (1 day)
- **Get it right**: See it again in 3 days
- **Get it right again**: See it again in 7 days
- **Get it right again**: See it in 9999 days (effectively archive it)

Why? Notes older than 4 weeks started interfering with newer, more immediately relevant content. This schedule keeps active material fresh while archiving mastered concepts. When exam time comes, I run a custom study session on archived cards, then let them fade back into the archive afterward.

### The Solution

Build a command-line tool that does everything I need Anki to do, but entirely in the terminal. Now my note-taking and review happen in the same environment. The system stores questions in plain text files and tracks scheduling in a SQLite database—I can sync between machines by sharing the text files, with the database automatically rebuilding the schedule based on file contents.

## What It Looks Like

### Directory Tree with Due Counts

When you run `anki` without arguments, you get a visual overview of your knowledge base with due question counts:

```
~/anki/
├── anki.db
├── programming/
│   ├── python.txt                  [5 due]
│   ├── javascript.txt              [0 due]
│   ├── algorithms.txt              [12 due]
│   └── databases/
│       ├── sql.txt                 [3 due]
│       └── postgres.txt            [0 due]
├── systems/
│   ├── networking.txt              [7 due]
│   └── linux-commands.txt          [15 due]
└── interview-prep/
    ├── behavioral.txt              [2 due]
    └── system-design.txt           [8 due]
```

### Note Format

Questions are stored in plain `.txt` files. Lines starting with `?` denote questions, and everything until the next `?` is the answer:

**`~/anki/programming/python.txt`**
```
? What's the difference between a list and a tuple in Python
Lists are mutable (can be modified after creation) using square brackets [1,2,3].
Tuples are immutable (cannot be modified) using parentheses (1,2,3).
Tuples are hashable and can be used as dictionary keys.

? Explain Python's GIL
The Global Interpreter Lock (GIL) is a mutex that protects access to Python objects,
preventing multiple threads from executing Python bytecode simultaneously.
This makes single-threaded programs fast but limits multi-threaded CPU-bound performance.
Use multiprocessing instead of threading for CPU-intensive parallel work.

? What does the `with` statement do
The `with` statement simplifies exception handling by encapsulating common preparation
and cleanup tasks in context managers. Guarantees that cleanup code runs even if an
exception occurs. Most commonly used for file handling: `with open('file.txt') as f:`
```

**`~/anki/programming/algorithms.txt`**
```
? What is the time complexity of binary search
O(log n) - we eliminate half the search space with each comparison.

? Explain quicksort's partitioning step
Choose a pivot element, rearrange array so elements smaller than pivot come before it
and larger elements come after. Pivot ends up in its final sorted position.
Then recursively sort the sub-arrays on either side.
Average O(n log n), worst case O(n²) if poorly chosen pivots.

? When should you use a hash table vs a binary search tree
Hash tables: O(1) average lookup, no ordering, better for simple key-value lookups
BST: O(log n) lookup, maintains sorted order, better when you need range queries or iteration in sorted order
```

**`~/anki/systems/sql.txt`**
```
? What's the difference between INNER JOIN and LEFT JOIN
INNER JOIN returns only rows with matches in both tables.
LEFT JOIN returns all rows from left table, with NULLs for non-matching right table rows.

? Explain database normalization
The process of organizing data to reduce redundancy and improve data integrity.
First normal form (1NF): Atomic values, no repeating groups
Second normal form (2NF): 1NF + no partial dependencies on composite keys
Third normal form (3NF): 2NF + no transitive dependencies

? What is an index and when should you use one
A data structure that improves query speed by creating a lookup table.
Use when: frequently querying/filtering on a column, column has high cardinality
Avoid when: small tables, columns with frequent writes, low cardinality columns
Trade-off: faster reads, slower writes and more storage
```

## Features

### 📚 Review Mode
Interactive flashcard sessions with your custom scheduling.

```bash
anki ~/anki/programming/python.txt        # Review due cards in a specific file
anki --review ~/anki/programming/         # Review all due cards in a directory
```

During review:
- **Enter**: Reveal answer
- **Any key** (except `-` or `1`): Mark correct, advance interval
- **1**: Mark incorrect, reset to beginning
- **-**: Skip (don't update schedule)

### 📊 Due Tree View
Visual overview of your knowledge base with per-file due question counts.

```bash
anki                    # Show tree for ~/anki
anki --due ~/notes      # Show tree for custom directory
```

### 🎯 Custom Study
Review questions without affecting their schedule—perfect for exam prep.

```bash
anki --custom ~/anki/interview-prep/     # Review archived cards before interviews
```

### 🗄️ Database Management

```bash
anki --init             # Initialize database (~/anki/anki.db)
anki --init /custom/path
```

## Installation

1. Download the script:
```bash
curl -o ~/.bash_anki.sh https://raw.githubusercontent.com/zachleach/Bash-Anki/main/bash_anki.sh
```

2. Source it in your `.bashrc` or `.bash_profile`:
```bash
echo 'source ~/.bash_anki.sh' >> ~/.bashrc
source ~/.bashrc
```

3. Install dependencies (if not already present):
```bash
# Debian/Ubuntu
sudo apt install sqlite3 ripgrep tree

# Arch Linux
sudo pacman -S sqlite ripgrep tree

# macOS
brew install sqlite ripgrep tree
```

4. Initialize the database:
```bash
anki --init
```

## How It Works

### Spaced Repetition Algorithm

The default configuration uses an exponential backoff approach:

1. **New questions** start with a multiplier of 0 (due immediately)
2. **Correct answer**: Next review in `3 × multiplier` days, increment multiplier
3. **Incorrect answer** (press `1`): Reset to multiplier 0
4. **Mastery**: After 3 successful reviews (multiplier > 3), question is considered mastered

**Default progression:**
```
Day 0:  New question (multiplier 0)
Day 0:  Correct → Review in 0 days (multiplier 1)
Day 0:  Correct → Review in 3 days (multiplier 2)
Day 3:  Correct → Review in 6 days (multiplier 3)
Day 9:  Correct → Mastered! (multiplier 4, no longer shown)
```

You can configure this to match your preferred schedule (like the 1 3 7 9999 pattern described above) by editing the script parameters.

### Technical Implementation

- **Question Identification**: Each question is hashed (SHA256) to create a unique identifier, allowing questions to be tracked even if moved between files
- **Database Schema**: Simple table with `question_hash`, `due_date`, `multiplier`, and `question_text`
- **Orphan Cleanup**: Before displaying the due tree, the system automatically removes database entries for questions that no longer exist in files
- **File Integrity**: Trailing whitespace is cleaned during review to prevent formatting drift

## Dependencies

- **sqlite3** - Database management
- **ripgrep (rg)** - Fast pattern matching for questions
- **tree** - Directory visualization
- **Standard Unix tools** - `sed`, `cut`, `sha256sum`, `date`, `find`, `sort`, `comm`

## Use Cases

- **Technical interview prep**: Algorithms, data structures, system design
- **Language learning**: Vocabulary, grammar rules, phrases
- **Certification study**: Facts, concepts, procedures
- **Knowledge retention**: Anything you want to remember long-term

