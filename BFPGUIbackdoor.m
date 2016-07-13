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
        % parameter for running contrast SD calculation
        contrastRunningVarianceWindow = 40;
        % video playing variables; step size for rewind and ffwd
        fastforwardFramerate = 5;
        rewindFramerate = -5;
        % this handle allows to access small function in the GUI and change
        % directly some of GUIs parameters, in case something breaks down;
        % it should be used with precaution, as it is like the Ring of
        % power, it can fix things, but break them as well, so make sure
        % You're more like Gandalf, than Rincewind.
        backdoorFunctionHandle;
    end
    
    methods 
        function obj = BFPGUIbackdoor(backdoorFunctionHandle_) % constructor
            obj.backdoorFunctionHandle = backdoorFunctionHandle_;   
        end
        
        % function to save only data of the object; Matlab otherwise tries
        % to save the graphical interface as part of this object
        function sobj = saveobj(obj)
            sobj.edgeDetectionKernelSemiframes = obj.edgeDetectionKernelSemiframes;
            sobj.backpassedVariable = obj.backpassedVariable;
            sobj.contrastPlateauDetectionSensitivity = obj.contrastPlateauDetectionSensitivity;
            sobj.contrastPlateauDetectionThreshold = obj.contrastPlateauDetectionThreshold;
            sobj.contrastPlateauDetectionLength = obj.contrastPlateauDetectionLength;
            sobj.contrastPlateauDetectionLimitLength = obj.contrastPlateauDetectionLimitLength;
            sobj.contrastPlateauDetectionLimit = obj.contrastPlateauDetectionLimit;
            sobj.fastforwardFramerate = obj.fastforwardFramerate;
            sobj.rewindFramerate = obj.rewindFramerate;
            %sobj.backdoorFunctionHandle = obj.backdoorFunctionHandle;
        end
        
        % sets 'selecting' variable in GUI to false
        function resetSelecting(obj)
            obj.backdoorFunctionHandle('reselect');
        end
        
        % deletes dead waitbars (actually all waitbars)
        function killDeadWaitbar(obj)
            obj.backdoorFunctionHandle('deadwaitbar');
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

