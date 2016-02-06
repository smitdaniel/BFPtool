classdef BFPGUIbackdoor < handle
    %BFPGUIbackdoor Hidden settings and parameters for BFP GUI
    %   This class contains parameters, which users might want to change,
    %   but whose default values are more or less failsafe for wide range
    %   of applications. The descriptive names of parameters are long to
    %   avoid excessive documentation.
    %   The GUI creates this object and passes it to matlab environment.
    %   Since the object inherits handle properties, user can tweak certain
    %   parameters using line commands.
    
    properties (Hidden = true)
        % number of frames of each side for the edge detection kernel used
        % to detect plateaux in the course of force; this defines the
        % domain of the kernel, not its width
        edgeDetectionKernelSemiframes = 10;
        % the variance of the gaussian kernel (before differentiation);
        % determines how sensitive the kernel is to local perturbations
        % edgeDetectionKernelSemiwidth  = 5;
        backpassedVariable = 1;
        % parameters for the detection of plateaux in the contrast. This
        % detection is supposed to help user to choose intact intervals
        % with stable contrast to perform trackig, and intervals of
        % fluctuating contrast to introduce breaks.
        contrastPlateauDetectionSensitivity = 8;
        contrastPlateauDetectionThreshold = 1;  % in multiples of STD
        contrastPlateauDetectionLength = 65;
        contrastPlateauDetectionLimitLength = 10;
        contrastPlateauDetectionLimit  = 0.95;
        % video playing variables; step size for rewind and ffwd
        fastforwardFramerate = 5;
        rewindFramerate = -5;
    end
    
    methods 
        function obj = BFPGUIbackdoor() % constructor
            
        end
        
        % testing if 'base' WS is connected to GUI
        function [val] = getTest(obj)
            val = obj.backpassedVariable;
        end
        
        % passing test variable from 'base' WS to GUI
        function setTest(obj,backVar)
            obj.backpassedVariable = backVar;
        end
        
    end
    
end

