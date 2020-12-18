//
//  ScanlineAppController.swift
//  scanline
//
//  Created by Scott J. Kleper on 12/2/17.
//

import Foundation
import ImageCaptureCore
import AppKit
import Quartz
import Vision  // for barcode -spf

class ScanlineAppController: NSObject, ScannerBrowserDelegate, ScannerControllerDelegate {
    let configuration: ScanConfiguration
    let logger: Logger
    let scannerBrowser: ScannerBrowser
    var scannerBrowserTimer: Timer?

    var scannerController: ScannerController?
    
    init(arguments: [String]) {
        configuration = ScanConfiguration(arguments: Array(arguments[1..<arguments.count]))
//        configuration = ScanConfiguration(arguments: ["-flatbed", "house", "-v"])
//        configuration = ScanConfiguration(arguments: ["-scanner", "Dell Color MFP E525w (31:4D:90)", "-exact", "-v"])
//        configuration = ScanConfiguration(arguments: ["-scanner", "epson", "-v", "-resolution", "600"])
//        configuration = ScanConfiguration(arguments: ["-list", "-v"])
//        configuration = ScanConfiguration(arguments: ["-scanner", "epson", "-v", "scanlinetest"])
        logger = Logger(configuration: configuration)
        scannerBrowser = ScannerBrowser(configuration: configuration, logger: logger)
        
        super.init()
        
        scannerBrowser.delegate = self
    }

    func go() {
        scannerBrowser.browse()
        
        let timerExpiration:Double = Double(configuration.config[ScanlineConfigOptionBrowseSecs] as? String ?? "10") ?? 10.0
        scannerBrowserTimer = Timer.scheduledTimer(withTimeInterval: timerExpiration, repeats: false) { _ in
            self.scannerBrowser.stopBrowsing()
        }
        
        logger.verbose("Waiting up to \(timerExpiration) seconds to find scanners")
    }

    func exit() {
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    func scan(scanner: ICScannerDevice) {
        scannerController = ScannerController(scanner: scanner, configuration: configuration, logger: logger)
        scannerController?.delegate = self
        scannerController?.scan()
    }

    // MARK: - ScannerBrowserDelegate
    
    func scannerBrowser(_ scannerBrowser: ScannerBrowser, didFinishBrowsingWithScanner scanner: ICScannerDevice?) {
        logger.verbose("Found scanner: \(scanner?.name ?? "[nil]")")
        scannerBrowserTimer?.invalidate()
        scannerBrowserTimer = nil
        
        guard configuration.config[ScanlineConfigOptionList] == nil else {
            exit()
            return
        }
        
        guard let scanner = scanner else {
            logger.log("No scanner was found.")
            exit()
            return
        }
        
        scan(scanner: scanner)
    }
    
    // MARK: - ScannerControllerDelegate
    
    func scannerControllerDidFail(_ scannerController: ScannerController) {
        logger.log("Failed to scan document.")
        exit()
    }
    
    func scannerControllerDidSucceed(_ scannerController: ScannerController) {
        exit()
    }

}



extension Int {
    // format to 2 decimal places
    func f02ld() -> String {
        return String(format: "%02ld", self)
    }
    
    func fld() -> String {
        return String(format: "%ld", self)
    }
}

class ScanlineOutputProcessor {
    let logger: Logger
    let configuration: ScanConfiguration
    let urls: [URL]
    
    init(urls: [URL], configuration: ScanConfiguration, logger: Logger) {
        self.urls = urls
        self.configuration = configuration
        self.logger = logger
    }
    
    func process() -> Bool {
        let wantsPDF = configuration.config[ScanlineConfigOptionJPEG] == nil && configuration.config[ScanlineConfigOptionTIFF] == nil
        if !wantsPDF {
            for url in urls {
                outputAndTag(url: url)
            }
        } else {
            // Combine into a single PDF
            if let combinedURL = combine(urls: urls) {
                outputAndTag(url: combinedURL)
            } else {
                logger.log("Error while creating PDF")
                return false
            }
        }
        
        return true
    }
    
    // add -spf cf. https://heartbeat.fritz.ai/building-a-barcode-scanner-in-swift-on-ios-9ad550e8f78b
    func detectHandler(request: VNRequest, error: Error?) {
        guard let observations = request.results else {
            //print("no result")
            return
        }
        self.logger.log ("barcode obs : \(observations.count)")
        let results = observations.map({$0 as? VNBarcodeObservation})
        for result in results {
            self.logger.log(result!.payloadStringValue!)
        }
    }
    
    /*func startDetection() {
       let request = VNDetectBarcodesRequest(completionHandler: self.detectHandler)
       request.symbologies = [VNBarcodeSymbology.code39] // or use .QR, etc
       self.requests = [request]
    }*/
    
    lazy var detectBarcodeRequest: VNDetectBarcodesRequest = {
        return VNDetectBarcodesRequest(completionHandler: { (request, error) in
            guard error == nil else {
                self.logger.log("Barcode Error \(error!.localizedDescription)")
                return
            }

            self.processClassification(for: request)
        })
    }()
    
    // MARK: - Vision
    func processClassification(for request: VNRequest) {
        //DispatchQueue.main.async {
            if let bestResult = request.results?.first as? VNBarcodeObservation,
                let payload = bestResult.payloadStringValue {
                self.logger.log (payload)
                //self.showInfo(for: payload)
            } else {
                self.logger.log("Unable to extract results: cannot extract barcode information from data.")
            }
        //}
    }
    
    func combine(urls: [URL]) -> URL? {
        let document = PDFDocument()
        
        
        for url in urls {
           
            //let ciImage = CIImage(contentsOf: url)
            let image = NSImage(byReferencing: url)
            let cgImage = image.cgImage! // extension method in UIImageAlias...
            //let imageData = image.tiffRepresentation!
            //let ciImage = CIImage(data: imageData.cop)
            //let src = CGImageSourceCreateWithURL(url as CFURL, nil)
            //let cgImage = CGImageSourceCreateImageAtIndex(src!, 0, nil)
            
            //let fname = url.description
            //let dataProvider = CGDataProvider(filename: fname)
            //let cgImage = CGImage(jpegDataProviderSource: dataProvider!, decode: nil, shouldInterpolate: false, intent: CGColorRenderingIntent(rawValue: 0)!)
            let textRequest = VNRecognizeTextRequest { request, error in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    fatalError("Received invalid observations")
                }

                for observation in observations {
                    guard let bestCandidate = observation.topCandidates(1).first else {
                        print("No candidate")
                        continue
                    }

                    print("Found this candidate: \(bestCandidate.string)")
                }
            }
            textRequest.recognitionLevel = .accurate
            
            let ocrHandler = VNImageRequestHandler(cgImage: cgImage, orientation: CGImagePropertyOrientation.up, options: [:])
            do {
                try ocrHandler.perform([textRequest])
            } catch {
                self.logger.log("Error Decoding OCR \(error.localizedDescription)")
            }
            
            let request = VNDetectBarcodesRequest(completionHandler: self.detectHandler)
            
            request.symbologies = [VNBarcodeSymbology.code39] // or use .QR, etc
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: CGImagePropertyOrientation.up, options: [:])
           
            do {
                try handler.perform([request])
            } catch {
                self.logger.log("Error Decoding Barcode \(error.localizedDescription)")
            }
            /*// Perform the classification request on a background thread.
            DispatchQueue.global(qos: .userInitiated).async {
                //let handler = VNImageRequestHandler(ciImage: ciImage!, orientation: CGImagePropertyOrientation.up, options: [:])
                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: CGImagePropertyOrientation.up, options: [:])
                do {
                    try handler.perform([self.detectBarcodeRequest])
                } catch {
                    self.logger.log("Error Decoding Barcode \(error.localizedDescription)")
                }
            }*/
            //let image = NSImage(byReferencing: url)
            if let page = PDFPage(image: image) {
                document.insert(page, at: document.pageCount)
            }
        }
        
        /*let group = DispatchGroup()
        group.enter()
        group.wait()*/
        
        let tempFilePath = "\(NSTemporaryDirectory())/scan.pdf"
        document.write(toFile: tempFilePath)
        
        return URL(fileURLWithPath: tempFilePath)
        
    }

    func outputAndTag(url: URL) {
        let gregorian = NSCalendar(calendarIdentifier: .gregorian)!
        let dateComponents = gregorian.components([.year, .hour, .minute, .second], from: Date())
        
        let outputRootDirectory = configuration.config[ScanlineConfigOptionDir] as! String
        var path = outputRootDirectory
        
        // If there's a tag, move the file to the first tag location
        if configuration.tags.count > 0 {
            path = "\(path)/\(configuration.tags[0])/\(dateComponents.year!.fld())"
        }
        
        logger.verbose("Output path: \(path)")

        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.log("Error while creating directory \(path)")
            return
        }
        
        let destinationFileExtension: String
        if configuration.config[ScanlineConfigOptionTIFF] != nil {
            destinationFileExtension = "tif"
        } else if configuration.config[ScanlineConfigOptionJPEG] != nil {
            destinationFileExtension = "jpg"
        } else {
            destinationFileExtension = "pdf"
        }
        
        let destinationFileRoot: String = { () -> String in
            if let fileName = self.configuration.config[ScanlineConfigOptionName] {
                return "\(path)/\(fileName)"
            }
            return "\(path)/scan_\(dateComponents.hour!.f02ld())\(dateComponents.minute!.f02ld())\(dateComponents.second!.f02ld())"
        }()
        
        var destinationFilePath = "\(destinationFileRoot).\(destinationFileExtension)"
        var i = 0
        while FileManager.default.fileExists(atPath: destinationFilePath) {
            destinationFilePath = "\(destinationFileRoot).\(i).\(destinationFileExtension)"
            i += 1
        }
        
        logger.verbose("About to copy \(url.absoluteString) to \(destinationFilePath)")

        let destinationURL = URL(fileURLWithPath: destinationFilePath)
        do {
            try FileManager.default.copyItem(at: url, to: destinationURL)
        } catch {
            logger.log("Error while copying file to \(destinationURL.absoluteString)")
            return
        }

        // Alias to all other tag locations
        // todo: this is super repetitive with above...
        if configuration.tags.count > 1 {
            for tag in configuration.tags.subarray(with: NSMakeRange(1, configuration.tags.count - 1)) {
                logger.verbose("Aliasing to tag \(tag)")
                let aliasDirPath = "\(outputRootDirectory)/\(tag)/\(dateComponents.year!.fld())"
                do {
                    try FileManager.default.createDirectory(atPath: aliasDirPath, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    logger.log("Error while creating directory \(aliasDirPath)")
                    return
                }
                let aliasFileRoot = { () -> String in
                    if let name = configuration.config[ScanlineConfigOptionName] {
                        return "\(aliasDirPath)/\(name)"
                    }
                    return "\(aliasDirPath)/scan_\(dateComponents.hour!.f02ld())\(dateComponents.minute!.f02ld())\(dateComponents.second!.f02ld())"
                }()
                var aliasFilePath = "\(aliasFileRoot).\(destinationFileExtension)"
                var i = 0
                while FileManager.default.fileExists(atPath: aliasFilePath) {
                    aliasFilePath = "\(aliasFileRoot).\(i).\(destinationFileExtension)"
                    i += 1
                }
                logger.verbose("Aliasing to \(aliasFilePath)")
                do {
                    try FileManager.default.createSymbolicLink(atPath: aliasFilePath, withDestinationPath: destinationFilePath)
                } catch {
                    logger.log("Error while creating alias at \(aliasFilePath)")
                    return
                }
            }
        }
        
        if configuration.config[ScanlineConfigOptionOpen] != nil {
            logger.verbose("Opening file at \(destinationFilePath)")
            NSWorkspace.shared.openFile(destinationFilePath)
        }
    }
}
