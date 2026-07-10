@echo off
REM Wrapper the XylosomeCaptureAgent scheduled task runs (avoids cmd quoting
REM fragility and buffers nothing: python -u writes the log in real time).
"C:\Users\Hoyte\AppData\Local\Programs\Python\Python313\python.exe" -u "C:\dev\xylosome-hmi\capture\capture_agent.py" >> "C:\dev\capture_agent.log" 2>&1
