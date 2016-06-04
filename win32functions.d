import std.stdio;
import std.process;
import std.string : startsWith, strip, indexOf;
import std.array : replace, split;
import std.datetime : Duration;

import core.vararg;

import vcs : StatusFlags;

// On Windows the following can happen:
//
// The user has installed git normally via Chocolately or MSI package
// so it can be used in cmd.exe. The user also has git installed
// as part of Cygwin via the Cygwin package manager.
// 
// Depending on which one is called the output of the following command 
// to get the project's root folder
//
//    auto rootFinder = execute(["git", "rev-parse", "--show-toplevel"]);
//
// is either C:\path\to\repro or /path/to/repro.
//
// If the cmd.exe version is called within a Cygwin terminal or vice-versa
// then all kinds of things go wrong with file and directory access.
//
// The problem is that D's standard library uses the 
//    version(Windows) { ... Win32 API calls ... }
//    version(Posix) { ... Posix calls ... }
// compiler directives to provide file access and read/write files.
// So internally it uses the Win32 API on Windows which expects C:\path style
// paths, unlike what Cygwin's git version gives us, which is /path style paths.
//
// So the file reading comes down crashing.
//
// If I compile in Cyginw then everything works as expected?
// No, unfortunately not, if the D compiler is installed using the MSI package
// (that is, it is not a Cygwin package). Not sure what would happen if you 
// installed D via a Cygwin package or even compile it from source in Cygwin though.
// Feel free to investigate that route.
//
// The solution for this case (Cygwin git, compiled promptoglyph-vcs.exe with 
// dmd.exe installed via non-cygwin-package, executing within Cygwin) is to
// convert the Unix style path to a Windows style one with the handy cygpath
// tool.
//

version (Windows)
{
	private:

	bool isCygWinEnv = false;
	bool testedForCygwin = false;

	import std.path : buildNormalizedPath;
	// Runtime Cygwin detection
	// NOTE(dkg): If you have a cleaner/better solution, please let me know. Thanks.
	//
	// UID is empty even in cygwin???
	// HOME is C:\Cygwin\home\<user> and not (as expected) /home/<user>
	//
	//void environmentTest()
	//{
	//	writeln("UID is   ",  environment.get("UID",   "empty"));
	//	writeln("HOME is  ",  environment.get("HOME",  "empty"));
	//	writeln("SHELL is ",  environment.get("SHELL", "empty"));
	//	writeln("TERM is  ",  environment.get("TERM",  "empty"));
	//}

	// NOTE(dkg): While this works, it is not particularly elegant.
	//            Maybe this could be improved by using program arguments
	//            instead to force a particular path style? So in
	//            Cygwin's bash you would pass something like "--cygwin"
	//            and then would just convert the paths always, so the 
	//            dynamic check during runtime would not be needed.
	public string customBuildPath(...)
	{
		if (!testedForCygwin) {
			// NOTE(dkg): If you know a better way to check during runtime
			//            whether or not we are in a Cygwin shell, then please
			//            let me know.
			isCygWinEnv = environment.get("SHELL", "") != "" && 
				environment.get("TERM", "") != "";
			testedForCygwin = true;
		}

		string s = "";
		for (int i = 0; i < _arguments.length; i++)
		{
			if (_arguments[i] == typeid(string[])) {
				string[] elements = va_arg!(string[])(_argptr);
				foreach (element; elements)
				{
					s = buildNormalizedPath(s, element);
				}
			} else {
				string element = va_arg!(string)(_argptr);
				s = buildNormalizedPath(s, element);
			}
		}
		if (isCygWinEnv) {
			// on cygwin - replace \ with /
			// also make sure that we convert the path to a Windows path
			// that means convernt /path to C:\path
			if (s.indexOf(":") <= -1) {
				s = s.replace("\\", "/");	
				if (s.startsWith("/")) {
					auto pathConversion = execute(["cygpath", "-w", s]);
					if (pathConversion.status != 0) {
						assert(false, "path could not be converted to Windows compatible path: " ~ s);
					}
					s = pathConversion.output.strip();
				//} else {
				//	assert(false, "path is not an absolute path: " ~ s);
				}
			}
		}
		return s;
	} // customBuildPath

	public
	void syncGetFlagsWin(StatusFlags* flags, void function(StatusFlags *ret, string line) processPorcelainLine, Duration allottedTime) 
	{
		import core.sys.windows.windows;
		import std.utf : toUTF16z;
		// NOTE(dkg): The wonders of the Win32 API are ... sigh. It's so ugly.
		//            I cobbled this together from some MSDN examples and stackoverflow
		//            and a lot of trial and error. So feel welcome to improve this.
		STARTUPINFO startupInfo;
		PROCESS_INFORMATION processInfo;

		scope(exit) {
			CloseHandle(processInfo.hProcess);
			CloseHandle(processInfo.hThread);
		}

		HANDLE g_hChildStd_IN_Rd = NULL;
		HANDLE g_hChildStd_IN_Wr = NULL;
		HANDLE g_hChildStd_OUT_Rd = NULL;
		HANDLE g_hChildStd_OUT_Wr = NULL;
		
		// Set the bInheritHandle flag so pipe handles are inherited. 
		SECURITY_ATTRIBUTES sa; 
		sa.nLength = SECURITY_ATTRIBUTES.sizeof; 
		sa.bInheritHandle = TRUE; 
		sa.lpSecurityDescriptor = NULL; 

		auto cmdptr = toUTF16z("git status --porcelain");
		const int BUFSIZE = 4096;
		uint timeLimit = cast(uint)allottedTime.total!"msecs";

		// Create a pipe for the child process's STDOUT. 
	    if (!CreatePipe(&g_hChildStd_OUT_Rd, &g_hChildStd_OUT_Wr, &sa, 0)) {
	        assert(false, "CreatePipe win32 api call failed.");
	    }
	    // Ensure the read handle to the pipe for STDOUT is not inherited
	    if (!SetHandleInformation(g_hChildStd_OUT_Rd, HANDLE_FLAG_INHERIT, 0)) {
	        assert(false, "SetHandleInformation win32 api call failed.");
	    }
		// Create a pipe for the child process's STDIN. 
		if (!CreatePipe(&g_hChildStd_IN_Rd, &g_hChildStd_IN_Wr, &sa, 0)) {
			assert(false, "2nd CreatePipe win32 api call failed.");
		}
		// Ensure the write handle to the pipe for STDIN is not inherited. 
		if (!SetHandleInformation(g_hChildStd_IN_Wr, HANDLE_FLAG_INHERIT, 0)) {
			assert(false, "2nd SetHandleInformation win32 api call failed.");
		}
		
		startupInfo.hStdError = g_hChildStd_OUT_Wr;
		startupInfo.hStdOutput = g_hChildStd_OUT_Wr;
		startupInfo.hStdInput = g_hChildStd_IN_Rd;
		startupInfo.dwFlags |= STARTF_USESTDHANDLES;
		startupInfo.cb = startupInfo.sizeof;
		
		if (CreateProcess(NULL, cast(wchar*)cmdptr, NULL, NULL, TRUE, 0, NULL, NULL, &startupInfo, &processInfo)) {
			int waitResult = WaitForSingleObject(processInfo.hProcess, timeLimit);
			
			// Read output from the child process's pipe for STDOUT
			// and write to the parent process's pipe for STDOUT. 
			// Stop when there is no more data. 
			string ReadFromPipe(PROCESS_INFORMATION piProcInfo) {
				DWORD dwRead; 
				char[BUFSIZE] chBuf;
				int bSuccess = false;
				string outstring = "";

				for (;;) {
					bSuccess = ReadFile(g_hChildStd_OUT_Rd, cast(void*)chBuf.ptr, BUFSIZE, &dwRead, NULL);
					
					if (!bSuccess || dwRead == 0) break; 
					
					string s = (cast(immutable(char)*)chBuf)[0..dwRead];
					outstring ~= s;

					if (dwRead < BUFSIZE) break;
				}
				dwRead = 0;
				//for (;;) { 
				//	bSuccess=ReadFile( g_hChildStd_ERR_Rd, chBuf, BUFSIZE, &dwRead, NULL);
				//	if( ! bSuccess || dwRead == 0 ) break; 

				//	string s(chBuf, dwRead);
				//	err += s;

				//} 
				return outstring;
			}
			
			if (waitResult == WAIT_TIMEOUT) {
				// terminate process
				if (!TerminateProcess(processInfo.hProcess, 1)) {
					// TODO(dkg): should we abandone ship here?
					writeln("warning: git status call process did not return in time and termination failed");
				}
			} else {
				string gitStatusResult = ReadFromPipe(processInfo);
				auto lines = gitStatusResult.split("\n");
				foreach (line; lines) {
					processPorcelainLine(flags, line);
				}
			}

			//CloseHandle(processInfo.hProcess);
			//CloseHandle(processInfo.hThread);
		}

	} // asyncGetFlagsWin

} // version(Windows)