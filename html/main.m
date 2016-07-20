%% BFPTool GUI
% BFPTool is a Matlab application allowing interactive analysis of
% recordings of experiments performed using BFP tool. It implements a GUI
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
% # Traking interval selection
% # Import/export
%
% * Computations:
%
% # Bead tracking
% # Pipette matching
% # Supplementary functions
%
% The Tool code is composed of 5 M-files:
%
% * _BFPGUI_ contains the whole GUI structure and GUI related functions
% * _BFPClass_ contains the crucial computational functions and
% organization of tasks
% * _TrackBead_ function responsible for tracking a selected bead in
% a pre-defined interval
% * _TrackPipette_ function reponsible for tracking the pipette tip pattern
% in a pre-defined interval
% * _vidWrap_ wrapper facilitating common interface for Matlab natively
% supported video formats and TIFF format (which is supported through
% LibTIFF library)

%% Installation and starting the tool
% The tool can be installed as a Matlab application into the application
% dashbar. At the *Apps* tab, click the button *Install App* and
% navigate to the installation file. The application can then be started by
% clicking its icon on the application dashbar.
%
% It can be also added as a folder of the M-files. Once the path to the
% folder is added to the Matlab path, the tool can be run using command
% *BFPGUI*.
%
% When starting the tool from the command line, more options are available.
% The tool returns a _BackDoor_ class object. This object allows user an
% access to some of the tool variables and functions, which are not
% accessible otherwise. The command also takes one optional input: calling
% BFPGUI(_saveddata.mat_) loads previously saved session (from file
% _saveddata.mat_).

