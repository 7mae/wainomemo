IF(LEN(Ids__c) >= 19,
IF(MID(Ids__c, 1, 1) = "I",
IMAGE("/sfc/servlet.shepherd/document/download/" & MID(Ids__c, 2, 18), LEFT(Labels__c, IF(FIND(";1;", Labels__c) = 0, LEN(Labels__c), FIND(";1;", Labels__c) - 1))),
HYPERLINK("/" & MID(Ids__c, 2, 18), LEFT(Labels__c, IF(FIND(";1;", Labels__c) = 0, LEN(Labels__c), FIND(";1;", Labels__c) - 1)))),
"")
&
IF(LEN(Ids__c) >= 38,
" " & BR() &
IF(MID(Ids__c, 20, 1) = "I",
IMAGE("/sfc/servlet.shepherd/document/download/" & MID(Ids__c, 21, 18), MID(Labels__c, FIND(";1;", Labels__c) + 3, IF(FIND(";2;", Labels__c) = 0, LEN(Labels__c) + 1, FIND(";2;", Labels__c)) - FIND(";1;", Labels__c) - 3)),
HYPERLINK("/" & MID(Ids__c, 21, 18), MID(Labels__c, FIND(";1;", Labels__c) + 3, IF(FIND(";2;", Labels__c) = 0, LEN(Labels__c) + 1, FIND(";2;", Labels__c)) - FIND(";1;", Labels__c) - 3))),
"")
&
IF(LEN(Ids__c) >= 57,
" " & BR() &
IF(MID(Ids__c, 39, 1) = "I",
IMAGE("/sfc/servlet.shepherd/document/download/" & MID(Ids__c, 40, 18), MID(Labels__c, FIND(";2;", Labels__c) + 3, IF(FIND(";3;", Labels__c) = 0, LEN(Labels__c) + 1, FIND(";3;", Labels__c)) - FIND(";2;", Labels__c) - 3)),
HYPERLINK("/" & MID(Ids__c, 40, 18), MID(Labels__c, FIND(";2;", Labels__c) + 3, IF(FIND(";3;", Labels__c) = 0, LEN(Labels__c) + 1, FIND(";3;", Labels__c)) - FIND(";2;", Labels__c) - 3))),
"")
&
IF(LEN(Ids__c) >= 76,
" " & BR() &
IF(MID(Ids__c, 58, 1) = "I",
IMAGE("/sfc/servlet.shepherd/document/download/" & MID(Ids__c, 59, 18), MID(Labels__c, FIND(";3;", Labels__c) + 3, IF(FIND(";4;", Labels__c) = 0, LEN(Labels__c) + 1, FIND(";4;", Labels__c)) - FIND(";3;", Labels__c) - 3)),
HYPERLINK("/" & MID(Ids__c, 59, 18), MID(Labels__c, FIND(";3;", Labels__c) + 3, IF(FIND(";4;", Labels__c) = 0, LEN(Labels__c) + 1, FIND(";4;", Labels__c)) - FIND(";3;", Labels__c) - 3))),
"")
&
IF(LEN(Ids__c) >= 95,
" " & BR() &
IF(MID(Ids__c, 77, 1) = "I",
IMAGE("/sfc/servlet.shepherd/document/download/" & MID(Ids__c, 78, 18), MID(Labels__c, FIND(";4;", Labels__c) + 3, IF(FIND(";5;", Labels__c) = 0, LEN(Labels__c) + 1, FIND(";5;", Labels__c)) - FIND(";4;", Labels__c) - 3)),
HYPERLINK("/" & MID(Ids__c, 78, 18), MID(Labels__c, FIND(";4;", Labels__c) + 3, IF(FIND(";5;", Labels__c) = 0, LEN(Labels__c) + 1, FIND(";5;", Labels__c)) - FIND(";4;", Labels__c) - 3))),
"")
&
IF(LEN(Ids__c) >= 114,
" " & BR() &
IF(MID(Ids__c, 96, 1) = "I",
IMAGE("/sfc/servlet.shepherd/document/download/" & MID(Ids__c, 97, 18), MID(Labels__c, FIND(";5;", Labels__c) + 3, LEN(Labels__c) - FIND(";5;", Labels__c) - 2)),
HYPERLINK("/" & MID(Ids__c, 97, 18), MID(Labels__c, FIND(";5;", Labels__c) + 3, LEN(Labels__c) - FIND(";5;", Labels__c) - 2))),
"")