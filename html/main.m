%% BFPTool GUI
% BFPTool is a Matlab application allowing interactive analysis of
% recordings of experiments performed using Biomembrane Force Probe (BFP) technique. It implements a GUI
% and contains computational tools.

%% Composition
% The tool consists of the graphical user interface (GUI) and
% computational methods.
%
% * GUI:
%
% # Video playback and tools
% # Tracking and calculation settings
% # Graphing and fitting tools
% # Tracking interval selection
% # Import/export
%
% * Computations:
%
% # Bead tracking
% # Pipette matching
% # Supplementary functions
%
% The Tool code is composed of 5+1 M-files:
%
% * _BFPGUI_ contains the whole GUI structure and GUI related functions
% * _BFPClass_ contains the crucial computational functions, stores 
% process data and performs organization of tasks 
% * _TrackBead_ function responsible for tracking the selected bead in
% a pre-defined interval
% * _TrackPipette_ function responsible for tracking the pipette tip pattern
% in a pre-defined interval
% * _vidWrap_ wrapper facilitating common interface for Matlab natively
% supported video formats and TIFF format (which is supported through
% LibTIFF library)
% * _BFPGUIbackdoor_ is a servicing object allowing to change some variables of
% the program. It does not contain any essential code

%% Installation and starting the tool
% The tool can be installed as a Matlab application into the application
% dashbar. At the *Apps* tab, click the button *Install App* and
% navigate to the installation file. The application can then be started by
% clicking its icon on the application dashbar.
%
% It can be also added as a folder of M-files. Once the path to the
% folder is added to the Matlab path (or set as a current Matlab path),
% the tool can be run using command
% *BFPGUI*. The command requires no inputs. Running the application creates
% a _BFPGUIbackdoor_ class object. This object allows user to
% access tool's variables and functions, which are not
% accessible otherwise (having mostly servicing function), note this object is 
% created every time the app is started. 
%
% When starting the tool from the command line, more options are available.
% The command takes one optional input: calling the BFPGUI with an
% argument BFPGUI(_saveddata.mat_), full path to a MAT file containing previously 
% saved session _saveddata.mat_, restores the session from the file. Note
% that the video used through the saved session must be available.
%
% The tool returns handle to the GUI figure, as recommended by Matlab
% documentation (the handle is not passed to the base workspace if started from the App dashbar).

