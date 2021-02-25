classdef ConcentricTubeRobot < handle
    %CONCENTRICTUBEROBOT is a subclass containing the entire kinematics of
    %the robot
    
    properties
        nTubes  % number of component tubes
        tubes   % nx1 vector of Precurved objects
        
        OD      % nx1 vector containing the tubes' inner diameters
        ID      % nx1 vector containing the tubes' inner diameters
        k       % nx1 vector containing the pre-curvature of each tube [mm^-1]
        Lc      % nx1 vector containing the lenghts of the precurved section of each tube
        Ls      % nx1 vector containing the lengths of straight section of each tube
        E       % nx1 vector containing the Young moduli of each tube
        I       % nx1 vector containins the second moment of inertia for each tube
        
        q       % nx[translation rotation] current configuration
        arcs
    end
    
    methods
        function self = ConcentricTubeRobot(OD, ID, k, Ls, Lc, E)
            n = length(OD);
            self.nTubes = n;
            
            for i = 1:n
                tubes(i) = Precurved(OD(i), ID(i), k(i), Ls(i), Lc(i), E);
            end
            self.tubes = tubes;
            self.OD = OD;
            self.ID = ID;
            self.k = k;
            self.Ls = Ls;
            self.Lc = Lc;
            self.E = E;
            self.I = [tubes.I];
        end
        
        function fwkine(self, q, torsional_rigid)
            %Calculates the forward kinematics of the complete robot
            %   converts joint to arcs to send to each tube
            %INPUT
            %   q = [nTubes x [translation rotation]] joint variables
            %   torsional_rigid (boolean) default true: assume torsional
            %   ridigity along straight sections of tube
            
            self.q = q;
            numOverlaps = 2*self.nTubes;
            
            % Calculate overlap lengths
            % matrix defining curved/straight/skip for each tube at each overlap
            % isCurved = zeros(numOverlaps, numTubes);
            [s, isCurved] = calcLinkLengths(self.tubes, q(:,1));
            
            % get emergent curvatures for each overlap section
            newK = zeros(numOverlaps, 1);  % init new ks for each overlapped section
            phi = zeros(numOverlaps, 1);
            
            if ~exist('torsional_rigid', 'var')
                torsional_rigid = true;
            end
            
            psi = q(:,2);   % default input angle to tubes is same as rotation
            
            % calculate actual psi based on torsional build up in tubes
            if ~torsional_rigid
                psi = self.calc_torsional_flex(q(:,2));
                disp('Input Angles with Torsion (deg)')
                disp(vpa(rad2deg(psi),4));
            end
            
            for  link = 1:numOverlaps
%                 [newK(link), phi(link)] = inplane_bending(self.tubes,q(:,2), isCurved(link,:));
                [newK(link), phi(link)] = self.inplane_bending(psi, isCurved(link,:));
            end
            
            arcs = self.links2arcs(numOverlaps, newK, phi, isCurved, s);
            
            self.arcs = arcs;
            
            for i = 1:self.nTubes
                self.tubes(i).fwkine(arcs(:,:,i));
            end
        end
        
        %% -----HELPERS----
        function [k_eq, phi_eq] = inplane_bending(self, theta, isCurved)
            %INPLANE_BENDING uses the elastic deformation formulas found in Webster2009
            %  to calculate the resulting curvature
            %  INPUTS
            %   thetas   = [n] array of base rotations
            %   isCurved = [n] optional array mapping if this section is curved
            %       1 = curved, 0 = straight, -1 = skip
            %  OUTPUTS
            %   k   =  curvature of link
            %   phi =  rotation of link
            
            % array that modifies isCurved for if the tube is there
            % if section is straight, still exists, but if -1 then does not
            % exist
            secExists = isCurved;
            secExists(secExists == 0) = 1;
            secExists(secExists == -1) = 0;
            
            % array that modifies isCurved for numerator
            addCurvature = isCurved;
            addCurvature(addCurvature == -1) = 0;
            
            M = self.E .* self.I;
            
            theta = reshape(theta, size(M));
            
            kx =  sum(M .* self.k .* cos(theta) .* addCurvature) / sum(M .* secExists);
            ky = sum(M .* self.k .* sin(theta) .* addCurvature) ./ sum(M .* secExists);
            
            if isnan(kx), kx = 0; end
            if isnan(ky), ky = 0; end
            
            k_eq = sqrt(kx.^2 + ky.^2);
            phi_eq = atan2(ky, kx);
        end
        
        function arcs = links2arcs(self, numOverlaps, newK, phi, isCurved, Ls)
            arcs = zeros(numOverlaps, 3, self.nTubes);
            for t = 1:self.nTubes
                
                curr_phi = 0;     % keeps track of current angle
                for link = 1:numOverlaps
                    k = newK(link);
                    abs_phi = phi(link);
                    s = Ls(link);
                    
                    % update relative theta
                    if curr_phi ~= abs_phi
                        rel_phi = abs_phi - curr_phi;
                        curr_phi = curr_phi + rel_phi;
                    else
                        rel_phi = 0;
                    end
                    
                    % if the section ends
                    if isCurved(link,t) == -1 || s == 0
                        k = 0;
                        s = 0;
                    end
                    
                    arcs(link,:,t) = [k rel_phi s];
                end
            end
        end
        
        function psi = calc_torsional_flex(self, alpha)
%             options = optimoptions('fsolve', 'OptimalityTolerance', 1e-10);
%             dU = @self.energy_func;
%             
%             initials = alpha;
%             psi = fsolve(dU, initials, options);
            
            
            guess_psi = alpha;
            F = self.get_psi_equations(guess_psi);
            psi1 = vpa(solve(F(1)), 4);
            psi2 = vpa(solve(F(2)), 4);
            
            psi = [psi1 psi2];
        end
        
        function F = get_psi_equations(self, guess_psi)
            syms psi1 psi2
            
            l1 = self.q(1,1);
            l2 = self.q(2,1);
            
            alpha1 = self.q(1,2);
            alpha2 = self.q(2,2);
            
            % consts
            J = 2 * self.I;
            
            v = .40; % .30 - .55
            G = 400e6;
            
            c1 = G * J(1)/self.Ls(1);
            c2 = G * J(2)/self.Ls(2);
            c3 = self.E*self.I(1)*self.E*self.I(2)*self.k(1)*self.k(2)/...
                        (self.E*self.I(1)+self.E*self.I(2));
                    
            b1 =  c3 / c1;
            b2 = c1 / c2;
                    
            f1_sine = taylor(alpha2 + b2*alpha1 - psi1*(1 + b2), psi1, guess_psi(1));
            
            % UDPATE WITH ACTUAL VALUE
            f2_sine = taylor(alpha1 + c2/c1*alpha2 - psi2*(1 + c2/c1), psi2, guess_psi(1));
            
            f1 = psi1 - alpha1 == l2 * b1 * f1_sine;
            f2 = psi2 - alpha2 == l2 * c3 / c2 * f2_sine;
            
            F = [f1 f2];
        end
        
        function F = energy_func(self, x)
            psi1 = x(1);
            psi2 = x(2);
            
            l1 = self.q(1,1);
            l2 = self.q(2,1);
            
            alpha1 = self.q(1,2);
            alpha2 = self.q(2,2);
            
            % consts
            J = 2 * self.I;
            
            v = .40; % .30 - .55
            G = 400e6;
            
            c1 = G * J(1)/self.Ls(1);
            c2 = G * J(2)/self.Ls(2);
            c3 = self.E*self.I(1)*self.E*self.I(2)*self.k(1)*self.k(2)/...
                        (self.E*self.I(1)+self.E*self.I(2));
            
            f1 = c3*l2*sin(psi1 - psi2) - (c1*(2*alpha1 - 2*psi1))./2;
            f2 = -(c2*(2*alpha2 - 2*psi2))./2 - c3*l2*sin(psi1 - psi2);

            F = [f1; f2];
        end
        
        function h = plotTubes(self)
            % PLOTTUBES creates a figure with 3D mesh of the tubes in their
            % current state
            % OUTPUT
            %   h = [n] vector of surf object handles
            
            h = zeros(1,self.nTubes);
            colors = distinguishable_colors(self.nTubes);
            figure('Name', 'Precurved Tubes');
            hold on
            
            for i = 1:self.nTubes
                model = self.tubes(i).makePhysicalModel();
                
                % mesh model of the tube
                h(i) = surf(model.surface.X, model.surface.Y, model.surface.Z,...
                    'FaceColor', colors(i,:));
                
                % create a triad (coord frame) for the transformations
                trans = self.tubes(i).transformations;
                for jj = 1:size(trans,3)
                    triad('Matrix', trans(:,:,jj), 'scale', 5e-3);
                end
                
                axis('image');
                view([135 30]);
                grid on;
                
                camlight('headlight');
                material('dull');
                axis equal
                xlabel('X (m)');
                ylabel('Y (m)');
                zlabel('Z (m)');
                title('Concentric Precurved Tubes with Deformation');
            end
        end
        
        function animateTubes(self, handles)
            % ANIMATETUBES updates tube meshes in figure with their latest
            % state
            % INPUT:
            %   handles = [n] handles of surface objects
            
            for i = 1:length(handles)
                model = self.tubes(i).makePhysicalModel();
                h = handles(i);
                
                h.XData = model.surface.X;
                h.YData = model.surface.Y;
                h.ZData = model.surface.Z;
                
                
            end
        end
    end
end

