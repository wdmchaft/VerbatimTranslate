//
//  ProtoMainViewController.h
//  ProtoMain
//
//  Created by Matt Weight on 9/15/10.
//  Copyright __MyCompanyName__ 2010. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface ProtoMainViewController : UIViewController <UITextFieldDelegate> {
	IBOutlet UITextField* translateTextField;
	IBOutlet UITextField* translateDestTextField;
}

- (IBAction) translate:(id)sender;

@end

