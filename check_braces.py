#!/usr/bin/env python3

def check_braces(file_path, start_line, end_line):
    with open(file_path, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    # Get only the lines we're interested in (adjust for 0-based indexing)
    js_lines = lines[start_line-1:end_line]  # Convert to 0-based index
    
    stack = []
    line_num = start_line  # Start counting from the actual starting line
    
    for i, line in enumerate(js_lines):
        for j, char in enumerate(line):
            if char == '{':
                stack.append((line_num, j + 1))  # Store line and column (1-based)
            elif char == '}':
                if stack:
                    stack.pop()
                else:
                    print(f"Unmatched closing brace at line {line_num}, column {j + 1}")
        
        line_num += 1
    
    if stack:
        for line_pos, col_pos in stack:
            print(f"Unclosed brace started at line {line_pos}, column {col_pos}")
    else:
        print("All braces are properly matched!")

if __name__ == "__main__":
    check_braces('/workspace/index_optimized.html', 527, 1365)