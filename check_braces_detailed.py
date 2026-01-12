#!/usr/bin/env python3

def check_braces_detailed(file_path, start_line, end_line):
    with open(file_path, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    # Get only the lines we're interested in (adjust for 0-based indexing)
    js_lines = lines[start_line-1:end_line]  # Convert to 0-based index
    
    stack = []  # Stack to keep track of opening braces and their positions
    unmatched_closing = []  # Track any unmatched closing braces
    
    line_num = start_line  # Start counting from the actual starting line
    
    for i, line in enumerate(js_lines):
        for j, char in enumerate(line):
            if char == '{':
                stack.append((line_num, j + 1, line.strip()))  # Store line, column, and content
            elif char == '}':
                if stack:
                    stack.pop()
                else:
                    unmatched_closing.append((line_num, j + 1))
        
        line_num += 1
    
    if unmatched_closing:
        print("Unmatched closing braces:")
        for pos in unmatched_closing:
            print(f"  Unmatched closing brace at line {pos[0]}, column {pos[1]}")
    
    if stack:
        print("Unclosed braces:")
        for pos, col, content in stack:
            print(f"  Unclosed brace started at line {pos}, column {col}: {content[:50]}...")
    else:
        print("All braces are properly matched!")

if __name__ == "__main__":
    check_braces_detailed('/workspace/index_optimized.html', 527, 1365)