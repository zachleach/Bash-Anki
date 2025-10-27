# Helper: Generate SHA256 hash for a question
function _anki_get_question_hash() {
	local question="$1"
	printf '%s\n' "${question}" | sha256sum | cut -d' ' -f1
}

# Helper: Check if a question is due (returns 0 if due, 1 if not)
function _anki_is_question_due() {
	local hash="$1"
	local result=$(sqlite3 $HOME/anki/anki.db "SELECT due_date, multiplier FROM schedule_info WHERE question_hash = '${hash}';" 2>/dev/null)

	if [[ -z "$result" ]]; then
		# question not in database = due by default
		return 0
	fi

	local due_date multiplier
	IFS='|' read due_date multiplier <<< "$result"

	# check if due and not mastered (multiplier <= 3)
	if [[ "$due_date" > "$(date +%Y-%m-%d)" ]] || [[ "$multiplier" -gt 3 ]]; then
		return 1
	else
		return 0
	fi
}

# Helper: Get all due questions from database, optionally filtered by file
function _anki_get_due_questions() {
	local file_filter="$1"
	local today=$(date +%Y-%m-%d)

	if [[ -n "$file_filter" ]]; then
		# get questions from specific file
		rg '^\?' "$file_filter" 2>/dev/null | while read question; do
			local hash=$(_anki_get_question_hash "$question")
			if _anki_is_question_due "$hash"; then
				echo "$question"
			fi
		done
	else
		# get all due questions from database
		sqlite3 $HOME/anki/anki.db "SELECT question_text FROM schedule_info WHERE due_date <= '${today}' AND multiplier <= 3;" 2>/dev/null
	fi
}

# Core: Count due questions in a file
_anki_count_due() {
	local file="$1"
	[[ ! -f "$file" ]] && echo "0" && return

	local count=0
	while read question; do
		local hash=$(_anki_get_question_hash "$question")
		if _anki_is_question_due "$hash"; then
			count=$((count + 1))
		fi
	done < <(rg '^\?' "$file" 2>/dev/null)

	echo "$count"
}

# Core: Initialize database with proper schema
_anki_init_database() {
	local anki_path="${1:-$HOME/anki}"
	local db_file="${anki_path}/anki.db"

	# check if database already exists
	if [[ -f "$db_file" ]]; then
		echo "Database already exists at: $db_file"
		return 0
	fi

	# create directory if it doesn't exist
	mkdir -p "$anki_path"

	# create database with schema
	sqlite3 "$db_file" <<EOF
CREATE TABLE schedule_info (
	question_hash TEXT PRIMARY KEY,
	due_date TEXT NOT NULL,
	multiplier INTEGER NOT NULL,
	question_text TEXT NOT NULL DEFAULT ''
);
EOF

	echo "Initialized anki database at: $db_file"
}

# Core: Clean up orphaned database entries (questions that no longer exist in files)
_anki_cleanup_orphaned() {
	local anki_path="${1:-$HOME/anki}"
	[[ ! -d "$anki_path" ]] && return

	# collect all current question hashes from .txt files
	local current_hashes=$(mktemp)
	find "$anki_path" -name "*.txt" -type f | while read filepath; do
		rg '^\?' "$filepath" 2>/dev/null | while read question; do
			_anki_get_question_hash "$question"
		done
	done | sort -u > "$current_hashes"

	# get all hashes from database
	local db_hashes=$(mktemp)
	sqlite3 $HOME/anki/anki.db "SELECT question_hash FROM schedule_info;" 2>/dev/null > "$db_hashes"

	# find orphaned hashes (in database but not in files)
	local orphaned_hashes=$(comm -13 "$current_hashes" "$db_hashes")

	# delete orphaned entries from database
	if [[ -n "$orphaned_hashes" ]]; then
		while read hash; do
			[[ -n "$hash" ]] && sqlite3 $HOME/anki/anki.db "DELETE FROM schedule_info WHERE question_hash = '${hash}';" 2>/dev/null
		done <<< "$orphaned_hashes"
	fi

	# cleanup temp files
	rm -f "$current_hashes" "$db_hashes"
}

# Core: Show directory tree with due question counts
_anki_show_due_tree() {
	local path="${1:-$HOME/anki}"
	[[ ! -e "$path" ]] && echo "Path not found: $path" && return

	# cleanup orphaned database entries before showing tree
	_anki_cleanup_orphaned "$path"

	if [[ -f "$path" ]]; then
		# single file
		local count=$(_anki_count_due "$path")
		echo "$(basename "$path") $count"
	else
		# directory - use tree command and append counts
		local temp_file=$(mktemp)
		tree -F "$path" > "$temp_file"

		# for each .txt file, get count and append to tree output
		find "$path" -name "*.txt" -type f | while read filepath; do
			local count=$(_anki_count_due "$filepath")
			local basename=$(basename "$filepath")
			# append count after the filename (handles tree characters before filename)
			sed -i "s|\(.*${basename}\)$|\1 ${count}|" "$temp_file"
		done

		# display tree output, removing last 2 lines (blank line + summary)
		head -n -2 "$temp_file"
		rm -f "$temp_file"
	fi
}

# Core: Review questions in a file (original anki logic)
_anki_review_file() {
	local file="$1"
	[[ ! -f "${file}" ]] && echo "File not found: ${file}" && return

	# there were some trailing whitespace bugs with sed; for simplicity, start by removing all trailing whitespace from every line in the input file
	sed -i 's/[[:space:]]*$//' "${file}"

	rg '^\?' "${file}" | while read question; do
		# get the question from the database
		hash=$(_anki_get_question_hash "$question")
		original_question="$question"
		result=$(sqlite3 $HOME/anki/anki.db "SELECT due_date, multiplier FROM schedule_info WHERE question_hash = '${hash}';" 2>/dev/null)

		if [[ -z "$result" ]]; then
			due_date=$(date +%Y-%m-%d)
			multiplier=0
		else
			IFS='|' read due_date multiplier <<< "$result"
		fi

		# skip if note isn't due or if successfully revied more than 3 times
		if [[ "$due_date" > "$(date +%Y-%m-%d)" ]] || [[ "$multiplier" -gt 3 ]]; then
			continue
		fi

		# show the question and wait for input
		clear
		echo "$question"
	read </dev/tty

		# show the question answer pair after input
		clear
		question=$(printf '%s\n' "$question" | sed 's/[]\/$*.^[]/\\&/g')
		sed -n "/^${question}$/,/^\?/p" "${file}" | head -n -4
		read response </dev/tty

		# update the database based on response (1 means re-learn, - means skip database update)
		if [[ "$response" != "-" ]]; then
			if [[ "$response" == "1" ]]; then
				multiplier=0
			else
				multiplier=$((multiplier + 1))
			fi

			due_date=$(date -d "+$((3 * multiplier)) days" +%Y-%m-%d)
			escaped_question="${original_question//\'/\'\'}"
			sqlite3 $HOME/anki/anki.db "INSERT OR REPLACE INTO schedule_info (question_hash, due_date, multiplier, question_text) VALUES ('${hash}', '${due_date}', ${multiplier}, '${escaped_question}');" 2>/dev/null
		fi
	done
}

# Core: Custom study mode - review all questions without updating database
_anki_custom_study() {
	local file="$1"
	[[ ! -f "${file}" ]] && echo "File not found: ${file}" && return

	# remove trailing whitespace from every line in the input file
	sed -i 's/[[:space:]]*$//' "${file}"

	rg '^\?' "${file}" | while read question; do
		original_question="$question"

		# show the question and wait for input
		clear
		echo "$question"
		read </dev/tty

		# show the question answer pair after input
		clear
		question=$(printf '%s\n' "$question" | sed 's/[]\/$*.^[]/\\&/g')
		sed -n "/^${question}$/,/^\?/p" "${file}" | head -n -4
		read response </dev/tty

		# no database updates in custom study mode
	done
}

# Main entry point with flag parsing
function anki() {
	local flag="$1"
	local path="$2"

	case "$flag" in
		--init)
			_anki_init_database "${path:-$HOME/anki}"
			;;
		--review)
			[[ -z "$path" ]] && echo "Usage: anki --review <file>" && return 1
			_anki_review_file "$path"
			;;
		--custom)
			[[ -z "$path" ]] && echo "Usage: anki --custom <file>" && return 1
			_anki_custom_study "$path"
			;;
		--due)
			_anki_show_due_tree "${path:-$HOME/anki}"
			;;
		*)
			# if first arg is a file, default to review mode
			if [[ -f "$flag" ]]; then
				_anki_review_file "$flag"
			else
				# otherwise show due tree
				cd $HOME/anki
				_anki_show_due_tree "${flag:-$HOME/anki}"
			fi
			;;
	esac
}
