debug(7 | 34);

import javax.swing.*;
import javax.swing.event.*;
import javax.swing.border.*;
import javax.imageio.*;

import java.awt.*;
import java.awt.event.*;

import msf.*;
import console.*;
import armitage.*;
import graph.*;

import java.awt.image.*;

global('$frame $tabs $menubar $msfrpc_handle $REMOTE');

sub describeHost {
	local('$sessions $os @overlay $ver $info');
	($sessions, $os, $ver) = values($1, @('sessions', 'os_name', 'os_flavor'));

	if (size($sessions) == 0) {
		return $1['address'];
	}

	$info = values($sessions)[0]["info"];
	if ("Microsoft Corp." isin $info) {
		return $1['address'] . "\nshell session";
	}
	else {
		return $1['address'] . "\n $+ $info";
	}
}

sub showHost {
	local('$sessions $os @overlay $match');
	($sessions, $os, $match) = values($1, @('sessions', 'os_name', 'os_flavor'));
	$os = normalize($os);

	if ($match eq "") {
		$match = $1['os_match'];
	}

	if ($os eq "Printer" || "*Printer*" iswm $match || "*embedded*" iswm lc($os)) {
		return overlay_images(@('resources/printer.png'));
	}
	else if ($os eq "Windows") {
		if ("*2000*" iswm $match || "*95*" iswm $match || "*98*" iswm $match || "*ME*" iswm $match || "*Me*" iswm $match) {
			push(@overlay, 'resources/windows2000.png');
		}
		else if ("*XP*" iswm $match || "*2003*" iswm $match || "*.NET*" iswm $match) {
			push(@overlay, 'resources/windowsxp.png');
		}
		else {
			push(@overlay, 'resources/windows7.png');
		}
	}
	else if ($os eq "Mac OS X" || "*apple*" iswm lc($os)) {
		push(@overlay, 'resources/macosx.png');
	}
	else if ("*linux*" iswm lc($os)) {
		push(@overlay, 'resources/linux.png');
	}
	else if ($os eq "IOS" || "*cisco*" iswm lc($os)) {
		push(@overlay, 'resources/cisco.png');
	}
	else if ("*BSD*" iswm $os) {
		push(@overlay, 'resources/bsd.png');
	}
	else if ($os eq "Solaris") {
		push(@overlay, 'resources/solaris.png');
	}
	else if ($os eq "VMware") {
		push(@overlay, 'resources/vmware.png');
	}
	else {
		push(@overlay, 'resources/unknown.png');
	}

	if (size($sessions) > 0) {
		push(@overlay, 'resources/hacked.png'); 
	}
	else {
		push(@overlay, 'resources/computer.png');
	}

	return overlay_images(@overlay);
}

sub connectToMetasploit {
	local('$thread $5');
	$thread = [new Thread: lambda(&_connectToMetasploit, \$1, \$2, \$3, \$4, \$5)];
	[$thread start];
}

sub _connectToMetasploit {
	global('$database $client $mclient $console @exploits @auxiliary @payloads @post');

	# update preferences

	local('%props $property $value $flag $exception');
	%props['connect.host.string'] = $1;
	%props['connect.port.string'] = $2;
	%props['connect.user.string'] = $3;
	%props['connect.pass.string'] = $4;

	if ($5 is $null) {
		foreach $property => $value (%props) {
			[$preferences setProperty: $property, $value];
		}
	}
	savePreferences();

	# setup progress monitor
	local('$progress');
	$progress = [new ProgressMonitor: $null, "Connecting to $1 $+ : $+ $2", "first try... wish me luck.", 0, 100];

	# keep track of whether we're connected to a local or remote Metasploit instance. This will affect what we expose.
	$REMOTE = iff($1 eq "127.0.0.1", $null, 1);

	$flag = 10;
	while ($flag) {
		try {
			if ([$progress isCanceled]) {
				if ($msfrpc_handle !is $null) {
					try {
						wait(fork({ closef($msfrpc_handle); }, \$msfrpc_handle), 5 * 1024);
						$msfrpc_handle = $null;
					}
					catch $exception {
						[JOptionPane showMessageDialog: $null, "Unable to shutdown MSFRPC programatically\nRestart Armitage and try again"];
						[System exit: 0];
					}
				}
				connectDialog();
				return;
			}

		        $client = [new MsgRpcImpl: $3, $4, $1, long($2), 1, $debug];
			$flag = $null;
		}
		catch $exception {
			[$progress setNote: [$exception getMessage]];
			[$progress setProgress: $flag];
			$flag++;
			sleep(2500);
		}
	}	
	$console = createConsole($client);
	let(&postSetup, \$progress);

	[$progress setNote: "Connected: Getting base directory"];
	[$progress setProgress: 30];

	setupBaseDirectory();

	if (!$REMOTE) {
		[$progress setNote: "Connected: Connecting to database"];
		[$progress setProgress: 40];

		try {
			# connect to the database plz...
			$database = connectToDatabase();
			[$client setDatabase: $database];
		}
		catch $exception {
			[JOptionPane showMessageDialog: $null, "Could not connect to database.\nClick Help button for troubleshooting help.\n\n" . [$exception getMessage]];
			if ($msfrpc_handle) { closef($msfrpc_handle); }
			[System exit: 0];
		}
	}

	[$progress setNote: "Connected: Getting local address"];
	[$progress setProgress: 50];

	getBindAddress();
	[$progress setNote: "Connected: Checking for collaboration server"];
	[$progress setProgress: 60];

	checkForCollaborationServer($client);
}

sub postSetup {
	thread(lambda({
		[$progress setNote: "Connected: Fetching exploits"];
		[$progress setProgress: 70];

		@exploits  = sorta(call($mclient, "module.exploits")["modules"]);

		[$progress setNote: "Connected: Fetching auxiliary modules"];
		[$progress setProgress: 80];

		@auxiliary = sorta(call($mclient, "module.auxiliary")["modules"]);

		[$progress setNote: "Connected: Fetching payloads"];
		[$progress setProgress: 90];

		@payloads  = sorta(call($mclient, "module.payloads")["modules"]);

		[$progress setNote: "Connected: Fetching post modules"];
		[$progress setProgress: 100];

		@post      = sorta(call($mclient, "module.post")["modules"]);

		[$progress close];
		main();
		createDashboard();
	}, \$progress));
}

sub main {
        local('$console $panel $dir');

	$frame = [new ArmitageApplication];
	[$frame setTitle: $TITLE];
        [$frame setSize: 800, 600];

	init_menus($frame);
	initLogSystem();

	[$frame setIconImage: [ImageIO read: resource("resources/armitage-icon.gif")]];
        [$frame show];
	[$frame setExtendedState: [JFrame MAXIMIZED_BOTH]];

	# this window listener is dead-lock waiting to happen. That's why we're adding it in a
	# separate thread (Sleep threads don't share data/locks).
	fork({
		[$frame addWindowListener: {
			if ($0 eq "windowClosing" && $msfrpc_handle !is $null) {
				closef($msfrpc_handle);
			}
		}];
	}, \$msfrpc_handle, \$frame);

	dispatchEvent({
		if ($client !is $mclient) {
			createEventLogTab();
		}
		else {
			createConsoleTab();
		}
	});

	if (-exists "command.txt") {
		deleteFile("command.txt");
	}
}

sub checkDir {
	# set the directory where everything exciting and fun will happen.
	if (cwd() eq "/Applications" || !-canwrite cwd() || isWindows()) {
		local('$dir');
		$dir = getFileProper(systemProperties()["user.home"], "armitage-tmp");
		if (!-exists $dir) {
			mkdir($dir);
		}
		chdir($dir);
		warn("Saving files to $dir");
	}
}

setLookAndFeel();
checkDir();

if ($CLIENT_CONFIG !is $null && -exists $CLIENT_CONFIG) {
	local('$config');
	$config = [new Properties];
	[$config load: [new java.io.FileInputStream: $CLIENT_CONFIG]];
	connectToMetasploit([$config getProperty: "host", "127.0.0.1"], 
				[$config getProperty: "port", "55553"],
				[$config getProperty: "user", "msf"],
				[$config getProperty: "pass", "test"], 1);
}
else {
	connectDialog();
}
